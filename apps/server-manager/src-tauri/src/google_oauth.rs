use crate::manager::GoogleOAuthConfig;
use crate::platform::open_system_browser;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    sync::{atomic::{AtomicBool, Ordering}, Arc, Mutex},
    thread,
    time::{Duration, Instant},
};
use url::Url;

const CALLBACK_PATH: &str = "/codmes-google-callback";
const CALLBACK_TIMEOUT: Duration = Duration::from_secs(10 * 60);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(2);
const IO_POLL_INTERVAL: Duration = Duration::from_millis(100);

#[derive(Default)]
pub struct SignInController(Mutex<Option<Arc<AtomicBool>>>);

impl SignInController {
    pub fn begin(&self) -> Result<SignInAttempt<'_>, String> {
        let mut active = self.0.lock().map_err(|error| error.to_string())?;
        if active.is_some() {
            return Err("A Google sign-in is already in progress.".into());
        }
        let cancelled = Arc::new(AtomicBool::new(false));
        *active = Some(cancelled.clone());
        Ok(SignInAttempt { controller: self, cancelled })
    }

    pub fn cancel(&self) {
        if let Ok(active) = self.0.lock() {
            if let Some(cancelled) = active.as_ref() {
                cancelled.store(true, Ordering::Relaxed);
            }
        }
    }
}

pub struct SignInAttempt<'a> {
    controller: &'a SignInController,
    cancelled: Arc<AtomicBool>,
}

impl SignInAttempt<'_> {
    pub fn cancellation_flag(&self) -> Arc<AtomicBool> { self.cancelled.clone() }

    pub fn check_cancelled(&self) -> Result<(), String> {
        if self.cancelled.load(Ordering::Relaxed) {
            Err("Google sign-in was cancelled.".into())
        } else {
            Ok(())
        }
    }
}

impl Drop for SignInAttempt<'_> {
    fn drop(&mut self) {
        if let Ok(mut active) = self.controller.0.lock() {
            if active.as_ref().is_some_and(|flag| Arc::ptr_eq(flag, &self.cancelled)) {
                *active = None;
            }
        }
    }
}

pub async fn obtain_id_token(config: GoogleOAuthConfig, cancelled: Arc<AtomicBool>) -> Result<String, String> {
    if config.desktop_client_id.is_empty() {
        return Err("Set up a Google Desktop OAuth Client ID first.".into());
    }
    if config.desktop_client_secret.is_empty() {
        return Err("This Server Manager build is missing its Google Desktop OAuth client secret. The Codmes distributor must rebuild it with the matching Desktop app credential.".into());
    }
    let listener = TcpListener::bind("127.0.0.1:0")
        .map_err(|error| format!("Could not open a local Google sign-in callback: {error}"))?;
    let port = listener.local_addr().map_err(|error| error.to_string())?.port();
    let redirect_uri = format!("http://127.0.0.1:{port}{CALLBACK_PATH}");
    let verifier = URL_SAFE_NO_PAD.encode(rand::random::<[u8; 32]>());
    let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
    let state = URL_SAFE_NO_PAD.encode(rand::random::<[u8; 32]>());
    let nonce = URL_SAFE_NO_PAD.encode(rand::random::<[u8; 32]>());

    let mut authorization = Url::parse("https://accounts.google.com/o/oauth2/v2/auth")
        .map_err(|error| error.to_string())?;
    authorization.query_pairs_mut()
        .append_pair("client_id", &config.desktop_client_id)
        .append_pair("redirect_uri", &redirect_uri)
        .append_pair("response_type", "code")
        .append_pair("scope", "openid email profile")
        .append_pair("state", &state)
        .append_pair("nonce", &nonce)
        .append_pair("code_challenge", &challenge)
        .append_pair("code_challenge_method", "S256")
        .append_pair("prompt", "select_account");
    if cancelled.load(Ordering::Relaxed) {
        return Err("Google sign-in was cancelled.".into());
    }
    open_system_browser(authorization.as_str())?;

    let callback_cancelled = cancelled.clone();
    let code = tauri::async_runtime::spawn_blocking(move || await_callback(listener, &state, &callback_cancelled))
        .await.map_err(|error| error.to_string())??;
    if cancelled.load(Ordering::Relaxed) {
        return Err("Google sign-in was cancelled.".into());
    }
    let client_id = config.desktop_client_id.clone();
    let fields = token_exchange_fields(config, code, redirect_uri, verifier);
    let response = reqwest::Client::builder()
        .timeout(Duration::from_secs(15))
        .build().map_err(|error| error.to_string())?
        .post("https://oauth2.googleapis.com/token")
        .form(&fields)
        .send().await.map_err(|error| format!("Google token exchange failed: {error}"))?;
    let status = response.status();
    let body: Value = response.json().await.map_err(|error| error.to_string())?;
    if cancelled.load(Ordering::Relaxed) {
        return Err("Google sign-in was cancelled.".into());
    }
    if !status.is_success() {
        return Err(body.get("error_description").and_then(Value::as_str)
            .or_else(|| body.get("error").and_then(Value::as_str))
            .unwrap_or("Google sign-in failed.").to_string());
    }
    let token = body.get("id_token").and_then(Value::as_str)
        .ok_or_else(|| "Google did not return an ID token.".to_string())?;
    validate_token_binding(token, &client_id, &nonce)?;
    Ok(token.to_owned())
}

// This binds Google's HTTPS response to this attempt. The Codmes backend separately
// verifies the JWT signature and the full identity claims against Google's keys.
fn validate_token_binding(token: &str, expected_client_id: &str, expected_nonce: &str) -> Result<(), String> {
    let invalid = || "Google sign-in response did not match this app and login attempt.".to_string();
    if token.len() > 16_384 { return Err(invalid()); }
    let segments: Vec<_> = token.split('.').collect();
    if segments.len() != 3 { return Err(invalid()); }
    let payload = URL_SAFE_NO_PAD.decode(segments[1]).map_err(|_| invalid())?;
    let claims: Value = serde_json::from_slice(&payload).map_err(|_| invalid())?;
    if claims.get("aud").and_then(Value::as_str) != Some(expected_client_id)
        || claims.get("nonce").and_then(Value::as_str) != Some(expected_nonce) {
        return Err(invalid());
    }
    Ok(())
}

fn token_exchange_fields(config: GoogleOAuthConfig, code: String, redirect_uri: String, verifier: String) -> Vec<(&'static str, String)> {
    vec![
        ("code", code),
        ("client_id", config.desktop_client_id),
        ("client_secret", config.desktop_client_secret),
        ("redirect_uri", redirect_uri),
        ("grant_type", "authorization_code".to_string()),
        ("code_verifier", verifier),
    ]
}

fn await_callback(listener: TcpListener, expected_state: &str, cancelled: &AtomicBool) -> Result<String, String> {
    await_callback_with_timeout(listener, expected_state, cancelled, CALLBACK_TIMEOUT)
}

fn await_callback_with_timeout(listener: TcpListener, expected_state: &str, cancelled: &AtomicBool, timeout: Duration) -> Result<String, String> {
    listener.set_nonblocking(true).map_err(|error| error.to_string())?;
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if cancelled.load(Ordering::Relaxed) {
            return Err("Google sign-in was cancelled.".into());
        }
        match listener.accept() {
            Ok((mut stream, _)) => {
                if let Some(result) = read_callback(&mut stream, expected_state, cancelled, deadline)? {
                    return result;
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(75));
            }
            Err(error) => return Err(format!("Google sign-in callback failed: {error}")),
        }
    }
    Err("Google sign-in timed out. Close the browser tab and try again.".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cancellation_stops_callback_wait_and_allows_another_attempt() {
        let controller = SignInController::default();
        let attempt = controller.begin().unwrap();
        assert!(controller.begin().is_err());
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let flag = attempt.cancellation_flag();
        let worker = thread::spawn(move || await_callback(listener, "expected", &flag));
        controller.cancel();
        assert!(worker.join().unwrap().unwrap_err().contains("cancelled"));
        drop(attempt);
        assert!(controller.begin().is_ok());
    }

    #[test]
    fn token_exchange_includes_matching_desktop_client_secret() {
        let config = GoogleOAuthConfig {
            desktop_client_id: "desktop-id".into(),
            desktop_client_secret: "matching-secret".into(),
            ..Default::default()
        };
        let fields = token_exchange_fields(config, "code".into(), "http://127.0.0.1/callback".into(), "verifier".into());
        assert!(fields.contains(&("client_id", "desktop-id".into())));
        assert!(fields.contains(&("client_secret", "matching-secret".into())));
        assert!(fields.contains(&("code_verifier", "verifier".into())));
    }

    #[test]
    fn token_must_match_publisher_and_login_attempt() {
        let payload = URL_SAFE_NO_PAD.encode(br#"{"aud":"publisher","nonce":"attempt"}"#);
        let token = format!("header.{payload}.signature");
        assert!(validate_token_binding(&token, "publisher", "attempt").is_ok());
        assert!(validate_token_binding(&token, "other-app", "attempt").is_err());
        assert!(validate_token_binding(&token, "publisher", "another-attempt").is_err());
        assert!(validate_token_binding("invalid", "publisher", "attempt").is_err());
    }

    #[test]
    fn idle_browser_connection_does_not_abort_sign_in() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        // Browsers can connect speculatively without sending an HTTP request.
        let _idle = TcpStream::connect(address).unwrap();
        let worker = thread::spawn(move || await_callback_with_timeout(listener, "expected", &AtomicBool::new(false), Duration::from_secs(5)));
        let mut callback = TcpStream::connect(address).unwrap();
        callback.write_all(b"GET /codmes-google-callback?state=expected&code=test-code HTTP/1.1\r\nHost: localhost\r\n\r\n").unwrap();
        assert_eq!(worker.join().unwrap().unwrap(), "test-code");
    }

    #[test]
    fn fragmented_callback_and_unrelated_requests_do_not_abort_sign_in() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let worker = thread::spawn(move || await_callback_with_timeout(listener, "expected", &AtomicBool::new(false), Duration::from_secs(5)));
        for request in [
            "GET /favicon.ico HTTP/1.1\r\nHost: localhost\r\n\r\n",
            "GET /codmes-google-callback?state=wrong&code=wrong HTTP/1.1\r\nHost: localhost\r\n\r\n",
        ] {
            let mut connection = TcpStream::connect(address).unwrap();
            connection.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
            connection.write_all(request.as_bytes()).unwrap();
            let _ = connection.read(&mut [0; 2048]);
        }
        let mut callback = TcpStream::connect(address).unwrap();
        callback.write_all(b"GET /codmes-google-callback?sta").unwrap();
        thread::sleep(Duration::from_millis(60));
        callback.write_all(b"te=expected&code=test-code HTTP/1.1\r\nHost: localhost\r\n\r\n").unwrap();
        assert_eq!(worker.join().unwrap().unwrap(), "test-code");
    }

    #[test]
    fn cancellation_interrupts_an_idle_connection() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let idle = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let cancelled = Arc::new(AtomicBool::new(false));
        let worker_flag = cancelled.clone();
        let started = Instant::now();
        let worker = thread::spawn(move || await_callback(listener, "expected", &worker_flag));
        thread::sleep(Duration::from_millis(50));
        cancelled.store(true, Ordering::Relaxed);
        assert!(worker.join().unwrap().unwrap_err().contains("cancelled"));
        assert!(started.elapsed() < Duration::from_secs(1));
        drop(idle);
    }

    #[test]
    fn callback_timeout_remains_bounded() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        assert!(await_callback_with_timeout(listener, "expected", &AtomicBool::new(false), Duration::from_millis(25))
            .unwrap_err().contains("timed out"));
        assert_eq!(CALLBACK_TIMEOUT, Duration::from_secs(600));
    }
}

fn read_callback(stream: &mut TcpStream, expected_state: &str, cancelled: &AtomicBool, login_deadline: Instant) -> Result<Option<Result<String, String>>, String> {
    // macOS can inherit O_NONBLOCK from the listening socket. A browser's TCP
    // connection can be accepted before its HTTP bytes arrive; EAGAIN must not
    // tear down the whole OAuth listener. Also tolerate speculative connections.
    stream.set_nonblocking(false).map_err(|error| error.to_string())?;
    stream.set_read_timeout(Some(IO_POLL_INTERVAL)).map_err(|error| error.to_string())?;
    let request_deadline = (Instant::now() + REQUEST_TIMEOUT).min(login_deadline);
    let mut bytes = Vec::with_capacity(1024);
    let line_end = loop {
        if cancelled.load(Ordering::Relaxed) {
            return Err("Google sign-in was cancelled.".into());
        }
        if Instant::now() >= request_deadline || bytes.len() >= 8192 { return Ok(None); }
        let mut chunk = [0_u8; 1024];
        match stream.read(&mut chunk) {
            Ok(0) => return Ok(None),
            Ok(count) => {
                bytes.extend_from_slice(&chunk[..count]);
                if let Some(end) = bytes.windows(2).position(|pair| pair == b"\r\n") { break end; }
            }
            Err(error) if matches!(error.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut | std::io::ErrorKind::Interrupted) => continue,
            // An abandoned/malformed individual browser connection must not
            // prevent the real Google redirect from being accepted later.
            Err(_) => return Ok(None),
        }
    };
    let Ok(first_line) = std::str::from_utf8(&bytes[..line_end]) else { return Ok(None) };
    let fields: Vec<_> = first_line.split_whitespace().collect();
    if fields.len() != 3 || fields[0] != "GET" || !fields[2].starts_with("HTTP/1.") { return Ok(None); }
    let target = fields[1];
    let Ok(url) = Url::parse(&format!("http://127.0.0.1{target}")) else { return Ok(None) };
    if url.path() != CALLBACK_PATH {
        send_callback_page(stream, false);
        return Ok(None);
    }
    let returned_state = url.query_pairs().find(|(key, _)| key == "state")
        .map(|(_, value)| value.into_owned());
    if returned_state.as_deref() != Some(expected_state) {
        send_callback_page(stream, false);
        return Ok(None);
    }
    if let Some(message) = url.query_pairs().find(|(key, _)| key == "error")
        .map(|(_, value)| value.into_owned()) {
        send_callback_page(stream, false);
        return Ok(Some(Err(format!("Google sign-in was cancelled or denied: {message}"))));
    }
    let code = url.query_pairs().find(|(key, _)| key == "code")
        .map(|(_, value)| value.into_owned());
    send_callback_page(stream, code.is_some());
    Ok(Some(code.ok_or_else(|| "Google did not return an authorization code.".into())))
}

fn send_callback_page(stream: &mut TcpStream, success: bool) {
    let _ = stream.set_write_timeout(Some(IO_POLL_INTERVAL));
    let message = if success { "Google response received. Return to Codmes Server Manager to check the sign-in result." }
        else { "Google sign-in could not be completed. Return to Codmes Server Manager." };
    let html = format!("<!doctype html><html><meta charset=\"utf-8\"><title>Codmes</title><body style=\"font:16px system-ui;padding:48px\"><h1>{message}</h1><p>You can close this tab.</p></body></html>");
    let response = format!("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{html}", html.len());
    let _ = stream.write_all(response.as_bytes());
}
