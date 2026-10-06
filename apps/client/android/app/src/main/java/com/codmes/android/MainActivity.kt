package com.codmes.android

import android.app.Activity
import android.app.AlertDialog
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.TextWatcher
import android.text.Editable
import java.io.File
import android.net.Uri
import android.util.Base64
import android.text.InputType
import android.view.ViewGroup
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.FrameLayout
import android.view.View
import android.view.Gravity
import android.view.WindowManager
import androidx.credentials.CredentialManager
import androidx.credentials.ClearCredentialStateRequest
import androidx.credentials.CustomCredential
import androidx.credentials.GetCredentialRequest
import com.google.android.libraries.identity.googleid.GetSignInWithGoogleOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONArray
import org.json.JSONObject
import java.security.SecureRandom
import java.security.MessageDigest
import kotlin.concurrent.thread

class MainActivity : Activity() {
    private lateinit var content: LinearLayout
    private lateinit var server: EditText
    private lateinit var token: EditText
    private var accountToken = ""
    private var accountServerURL = ""
    private var activeProfileId = ""
    private var activeProfileName = ""
    private var googleWebClientId = ""
    private var googleSignInBusy = false
    private var googleAccountLabel = ""
    private var setupGoogleToken = ""
    private var setupGoogleServer = ""
    private var setupGoogleCreated = 0L
    private var accountIdentity = JSONObject()
    private lateinit var appLock: DeviceAppLock
    private lateinit var lockCurtain: LinearLayout
    private lateinit var workspacePanel: LinearLayout
    private val http = OkHttpClient()
    private val documents = mutableMapOf<String, VersionedDocument>()
    private var flushLocalEditor: (() -> Unit)? = null
    private var syncCurrentEditor: (() -> Unit)? = null
    private var localEditorSaveFailed = false
    private val reconnectHandler = Handler(Looper.getMainLooper())
    private val reconnect = object : Runnable {
        override fun run() { syncCurrentEditor?.invoke(); reconnectHandler.postDelayed(this, 15_000) }
    }
    private var liveSocket: WebSocket? = null
    private var liveSessionId: String? = null
    private var pendingChatMessage: String? = null
    private var transcript: TextView? = null
    private val formFactor: String
        get() = if (resources.configuration.smallestScreenWidthDp >= 600) "tablet" else "phone"

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        appLock = DeviceAppLock(this)
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(24, 24, 24, 24) }
        workspacePanel = root
        server = EditText(this).apply { hint = "Workspace server"; setText("http://10.0.2.2:8787") }
        token = EditText(this)
        content = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(server)
        root.addView(Button(this).apply { text = "Connect"; setOnClickListener { showServerLogin() } })
        root.addView(ScrollView(this).apply { addView(content) }, LinearLayout.LayoutParams(-1, 0, 1f))
        val frame = FrameLayout(this)
        frame.addView(root, FrameLayout.LayoutParams(-1, -1))
        lockCurtain = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER; setPadding(48, 48, 48, 48)
            setBackgroundColor(Color.WHITE); visibility = View.GONE
        }
        frame.addView(lockCurtain, FrameLayout.LayoutParams(-1, -1))
        setContentView(frame)
        lockApp()
    }

    override fun onStop() { flushLocalEditor?.invoke(); super.onStop(); if (!googleSignInBusy) lockApp() }
    override fun onResume() { super.onResume(); reconnectHandler.removeCallbacks(reconnect); reconnectHandler.postDelayed(reconnect, 15_000) }
    override fun onPause() { reconnectHandler.removeCallbacks(reconnect); super.onPause() }

    private fun updateAppLockPrivacy() {
        if (appLock.enabled) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    private fun lockApp() {
        updateAppLockPrivacy()
        if (!appLock.enabled) return
        workspacePanel.visibility = View.INVISIBLE
        lockCurtain.visibility = View.VISIBLE
        lockCurtain.removeAllViews()
        lockCurtain.addView(title("Codmes app lock"))
        val pin = EditText(this).apply {
            hint = "PIN (four digits)"; inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD
        }
        val status = text("")
        lockCurtain.addView(pin)
        lockCurtain.addView(Button(this).apply {
            text = "Unlock"
            setOnClickListener {
                try {
                    appLock.authorize(pin.text.toString())
                    lockCurtain.visibility = View.GONE
                    workspacePanel.visibility = View.VISIBLE
                } catch (error: Exception) { status.text = error.message }
                finally { pin.setText("") }
            }
        })
        lockCurtain.addView(status)
    }

    private fun addAppLockSettings(panel: LinearLayout) {
        panel.addView(title("App lock (optional)"))
        panel.addView(text("This device only. Locks on launch and when leaving the app. Not a server credential or file encryption."))
        fun pinField(hintText: String) = EditText(this).apply {
            hint = hintText; inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD
        }
        val current = pinField("Current PIN")
        val pin = pinField("New PIN (four digits)")
        val confirmation = pinField("Confirm PIN")
        if (appLock.enabled) panel.addView(current)
        panel.addView(pin); panel.addView(confirmation)
        val status = text("")
        panel.addView(Button(this).apply {
            text = if (appLock.enabled) "Change app lock PIN" else "Enable app lock"
            setOnClickListener {
                try {
                    appLock.set(current.text.toString(), pin.text.toString(), confirmation.text.toString())
                    updateAppLockPrivacy(); showProfileSettings()
                } catch (error: Exception) { status.text = error.message }
                finally { current.setText(""); pin.setText(""); confirmation.setText("") }
            }
        })
        if (appLock.enabled) {
            panel.addView(Button(this).apply {
                text = "Disable app lock"
                setOnClickListener {
                    try { appLock.disable(current.text.toString()); updateAppLockPrivacy(); showProfileSettings() }
                    catch (error: Exception) { status.text = error.message }
                    finally { current.setText("") }
                }
            })
            panel.addView(Button(this).apply { text = "Lock now"; setOnClickListener { lockApp() } })
        }
        panel.addView(status)
    }

    private fun showServerLogin() {
        flushLocalEditor?.invoke(); if (localEditorSaveFailed) return
        disconnectChat()
        activeProfileId = ""
        token.setText("")
        if (accountServerURL != server.text.toString().trimEnd('/')) accountToken = ""
        if (accountToken.isNotEmpty()) { loadProfiles(); return }
        requestJson("GET", "/api/google-auth/config", null, { status ->
            val setup = status.optBoolean("bootstrapRequired")
            val serverClientId = status.optJSONObject("clientIds")?.optString("web").orEmpty()
            googleWebClientId = BuildConfig.GOOGLE_WEB_CLIENT_ID.takeIf { it == serverClientId }.orEmpty()
            show { panel ->
                panel.addView(title("Sign in to Codmes"))
                if (setup) {
                    panel.addView(text("Set up the first administrator in Codmes Server Manager on the server computer, then connect again."))
                    return@show
                }
                addCodmesLoginFields(panel, false)
                if (status.optBoolean("enabled") && googleWebClientId.isNotEmpty()) {
                    panel.addView(Button(this).apply {
                        text = "Continue with Google"
                        setOnClickListener { signInWithGoogle() }
                    })
                } else {
                    panel.addView(text("This app and Server Manager need matching publisher Google login settings. Server owners do not need their own Google Cloud project."))
                }
            }
        }, "")
    }

    private fun addCodmesLoginFields(panel: LinearLayout, signup: Boolean, setup: Boolean = false) {
        val username = EditText(this).apply { hint = "Codmes ID (3–64 characters)"; inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD }
        val password = EditText(this).apply { hint = if (signup) "Password (15–128 characters)" else "Password"; inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD }
        val confirmation = EditText(this).apply { hint = "Confirm password"; inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD }
        panel.addView(username); panel.addView(password); if (signup) panel.addView(confirmation)
        panel.addView(Button(this).apply {
            text = if (setup) "Complete account setup" else if (signup) "Sign up" else "Sign in"
            setOnClickListener {
                val pass = password.text.toString()
                if (signup && (pass.length !in 15..128 || pass != confirmation.text.toString())) {
                    AlertDialog.Builder(this@MainActivity).setMessage("Use 15–128 characters and match the confirmation.").setPositiveButton("OK",null).show()
                    return@setOnClickListener
                }
                val fields = JSONObject().put("username",username.text.toString()).put("password",pass).put("deviceId",deviceId()).put("deviceName",android.os.Build.MODEL)
                if (setup && accountToken.isNotEmpty()) {
                    requestJson("POST","/api/auth/account/credentials",fields,{ password.setText(""); confirmation.setText("");loadProfiles() },accountToken)
                } else {
                    val path: String
                    if (setup && setupGoogleToken.isNotEmpty()) {
                        if (setupGoogleServer != server.text.toString().trimEnd('/') || System.currentTimeMillis()-setupGoogleCreated>600000) { showMessage("Google sign-in expired. Sign in again.");return@setOnClickListener }
                        fields.put("idToken",setupGoogleToken);path="/api/google-auth/client/login"
                    } else path=if(signup) "/api/auth/client/register" else "/api/auth/client/login"
                    requestJson("POST",path,fields,{setupGoogleToken="";password.setText("");confirmation.setText("");handleGoogleLogin(it)},"")
                }
            }
        })
        panel.addView(Button(this).apply {
            text = if (setup) "Cancel / existing account" else if (signup) "Already have an account? Sign in" else "Create a Codmes account"
            setOnClickListener {
                setupGoogleToken=""
                if(setup) { accountToken="";showServerLogin() }
                else show { next -> next.addView(title(if(signup) "Sign in" else "Sign up"));addCodmesLoginFields(next,!signup) }
            }
        })
    }

    private fun addCodmesAccountSettings(panel: LinearLayout) {
        panel.addView(title("Codmes account / login methods"))
        panel.addView(text("Google: "+if(accountIdentity.optBoolean("googleLinked")) accountIdentity.optString("email") else "Not connected"))
        val current=EditText(this).apply { hint="Current Codmes password";inputType=InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD }
        panel.addView(current)
        panel.addView(Button(this).apply { text="Connect / change Google";setOnClickListener { if(current.text.isNotEmpty()) signInWithGoogle(current.text.toString()) } })
        if(accountIdentity.optBoolean("googleLinked")) panel.addView(Button(this).apply {
            text="Disconnect Google"
            setOnClickListener {
                if(current.text.isEmpty()) return@setOnClickListener
                AlertDialog.Builder(this@MainActivity).setMessage("Disconnect Google? Codmes ID/password, profile and approvals are preserved.")
                    .setNegativeButton("Cancel",null).setPositiveButton("Disconnect") { _,_->
                        requestJson("POST","/api/auth/account/google/unlink",JSONObject().put("currentPassword",current.text.toString()),{current.setText("");loadProfiles()},accountToken)
                    }.show()
            }
        })
        val password=EditText(this).apply { hint="New password (15–128 characters)";inputType=InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD }
        val confirmation=EditText(this).apply { hint="Confirm new password";inputType=InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD }
        panel.addView(password);panel.addView(confirmation)
        panel.addView(Button(this).apply {
            text="Change password"
            setOnClickListener {
                val pass=password.text.toString()
                if(current.text.isEmpty() || pass.length !in 15..128 || pass!=confirmation.text.toString()) return@setOnClickListener
                requestJson("POST","/api/auth/account/password",JSONObject().put("currentPassword",current.text.toString()).put("password",pass),{current.setText("");password.setText("");confirmation.setText("");loadProfiles()},accountToken)
            }
        })
        panel.addView(text("Login-method changes keep your profile and approved devices, and sign out other sessions. Manage administrator accounts in Server Manager."))
    }

    private fun deviceId(): String {
        val preferences = getSharedPreferences("codmes-device", MODE_PRIVATE)
        val serverHash = MessageDigest.getInstance("SHA-256")
            .digest(server.text.toString().trimEnd('/').toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
        val key = "id-$serverHash"
        preferences.getString(key, null)?.takeIf { it.length >= 43 }?.let { return it }
        val bytes = ByteArray(32).also { SecureRandom().nextBytes(it) }
        val identifier = Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
        preferences.edit().putString(key, identifier).apply()
        return identifier
    }

    private fun signInWithGoogle(linkPassword: String? = null) {
        if (googleSignInBusy) return
        val serverUrl = server.text.toString().trimEnd('/')
        val uri = Uri.parse(serverUrl)
        if (uri.scheme != "https" && !(uri.scheme == "http" && uri.host in setOf("127.0.0.1", "localhost", "::1"))) {
            showMessage("Google sign-in requires HTTPS for a remote Codmes server.")
            return
        }
        if (googleWebClientId.isEmpty()) { showMessage("Google OAuth is not configured on this server."); return }
        val originalAccountToken = accountToken
        googleSignInBusy = true
        CoroutineScope(Dispatchers.Main).launch {
            try {
                val option = GetSignInWithGoogleOption.Builder(googleWebClientId).build()
                val request = GetCredentialRequest.Builder().addCredentialOption(option).build()
                val credential = CredentialManager.create(this@MainActivity).getCredential(this@MainActivity, request).credential
                if (credential !is CustomCredential || credential.type != GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_CREDENTIAL) {
                    error("Google did not return an ID token.")
                }
                val idToken = GoogleIdTokenCredential.createFrom(credential.data).idToken
                if (server.text.toString().trimEnd('/') != serverUrl) return@launch
                val body = JSONObject().put("idToken", idToken).put("deviceId", deviceId())
                    .put("deviceName", android.os.Build.MODEL)
                if (linkPassword != null) {
                    if (accountToken != originalAccountToken) return@launch
                    body.put("currentPassword", linkPassword)
                    requestJson("POST", "/api/auth/account/google/link", body, { loadProfiles(); showProfileSettings() }, originalAccountToken)
                } else {
                    requestJson("POST", "/api/google-auth/client/login", body, {
                        if (it.optString("status") == "account_setup_required") {
                            setupGoogleToken = idToken; setupGoogleServer = serverUrl; setupGoogleCreated = System.currentTimeMillis()
                        }
                        handleGoogleLogin(it)
                    }, "")
                }
            } catch (error: Exception) { showMessage(error.message ?: "Google sign-in failed") }
            finally { googleSignInBusy = false }
        }
    }

    private fun handleGoogleLogin(result: JSONObject, pendingRequestId: String? = null, pendingRequestToken: String? = null) {
        when (result.optString("status")) {
            "account_setup_required" -> show { panel -> panel.addView(title("Set up your Codmes account")); panel.addView(text("Choose your ID/password once. Existing account and data are preserved.")); addCodmesLoginFields(panel,true,true) }
            "approved" -> {
                accountToken = result.getString("token")
                accountServerURL = server.text.toString().trimEnd('/')
                loadProfiles()
            }
            "pending" -> {
                val requestId = pendingRequestId ?: result.getString("requestId")
                val requestToken = pendingRequestToken ?: result.getString("requestToken")
                show { panel ->
                    panel.addView(title("Waiting for server approval"))
                    panel.addView(text("Ask the server administrator to approve this device in Server Manager."))
                    panel.addView(text("This request expires after 10 minutes. If it expires, sign in with Google again."))
                    panel.addView(Button(this).apply {
                        text = "Check approval"
                        setOnClickListener {
                            requestJson("POST", "/api/google-auth/client/status",
                                JSONObject().put("requestId", requestId).put("requestToken", requestToken),
                                { handleGoogleLogin(it, requestId, requestToken) }, "")
                        }
                    })
                    panel.addView(Button(this).apply {
                        text = "Sign in with Google again"
                        setOnClickListener { signInWithGoogle() }
                    })
                }
            }
            "rejected" -> showMessage("The server administrator rejected this device.")
            else -> showMessage("Google sign-in did not complete.")
        }
    }

    private fun loadProfiles() {
        disconnectChat()
        token.setText("")
        activeProfileId = ""
        requestJson("POST", "/api/client/profile/register", JSONObject(), { response ->
            val user = response.getJSONObject("user")
            accountIdentity = user
            googleAccountLabel = user.getString("displayName") + " · ID: " + user.optString("username") + " · " + user.optString("email")
            if (!user.optBoolean("credentialsConfigured")) { show { panel -> panel.addView(title("Set up your Codmes account")); addCodmesLoginFields(panel,true,true) }; return@requestJson }
            val profile = response.getJSONObject("profile")
            val id = profile.getString("id")
            requestJson("POST", "/api/profiles/${encode(id)}/open", JSONObject(), { opened ->
                token.setText(opened.getString("token"))
                activeProfileId = id
                activeProfileName = profile.getString("name")
                loadPlugins()
            }, accountToken)
        }, accountToken)
    }

    private fun showProfileSettings() {
        if (activeProfileId.isEmpty()) { loadProfiles(); return }
        show { panel ->
            panel.addView(title("Account · $activeProfileName"))
            panel.addView(text(googleAccountLabel))
            panel.addView(text("Your Codmes account automatically selects your profile. This profile is shared across approved devices on this server."))
            panel.addView(Button(this).apply {
                text = "Sign out / another account"
                setOnClickListener {
                    val oldToken = accountToken
                    val serverURL = server.text.toString().trimEnd('/')
                    accountToken = ""
                    googleAccountLabel = ""
                    activeProfileId = ""
                    token.setText("")
                    if (oldToken.isNotEmpty()) thread {
                        try {
                            val request = Request.Builder().url(serverURL + "/api/auth/logout")
                                .header("Authorization", "Bearer $oldToken")
                                .post(ByteArray(0).toRequestBody()).build()
                            http.newCall(request).execute().close()
                        } catch (_: Exception) { }
                    }
                    CoroutineScope(Dispatchers.Main).launch {
                        try { CredentialManager.create(this@MainActivity).clearCredentialState(ClearCredentialStateRequest()) }
                        catch (_: Exception) { }
                    }
                    showServerLogin()
                }
            })
            panel.addView(Button(this).apply {
                text = "Delete profile"
                setOnClickListener {
                    AlertDialog.Builder(this@MainActivity)
                        .setTitle("Delete $activeProfileName?")
                        .setMessage("This affects all devices using this Codmes account. Server Manager can restore its data.")
                        .setNegativeButton("Cancel", null)
                        .setPositiveButton("Delete") { _, _ ->
                            requestJson("POST", "/api/profiles/${encode(activeProfileId)}/archive", JSONObject(), {
                                token.setText("")
                                activeProfileId = ""
                                loadProfiles()
                            }, accountToken)
                        }.show()
                }
            })
            addCodmesAccountSettings(panel)
            addAppLockSettings(panel)
            panel.addView(Button(this).apply { text = "Back"; setOnClickListener { loadPlugins() } })
        }
    }

    private fun loadPlugins(): Unit { request("/api/plugins") { response ->
        val plugins = response.getJSONArray("plugins")
        show { panel ->
            panel.addView(title("Codmes · android + $formFactor"))
            panel.addView(text(googleAccountLabel))
            panel.addView(Button(this).apply {
                text = "Profile settings"
                setOnClickListener { showProfileSettings() }
            })
            panel.addView(Button(this).apply {
                text = "Pending approvals"
                setOnClickListener { openApprovals() }
            })
            for (index in 0 until plugins.length()) {
                val plugin = plugins.getJSONObject(index)
                if (!supportsCurrentDevice(plugin)) continue
                val pluginId = plugin.getString("id")
                if (!plugin.optBoolean("builtIn", false)) {
                    panel.addView(Button(this).apply {
                        text = "${plugin.getString("name")} · MCP tools"
                        setOnClickListener { openMcpTools(pluginId) }
                    })
                }
                val views = plugin.optJSONArray("views") ?: JSONArray()
                for (viewIndex in 0 until views.length()) {
                    val view = views.getJSONObject(viewIndex)
                    panel.addView(Button(this).apply {
                        text = "${plugin.getString("name")} · ${view.getString("title")}"
                        setOnClickListener {
                            if (view.optString("renderer") == "declarative") {
                                loadSurface(plugin.getString("id"))
                            } else {
                                when (view.optString("id")) {
                                    "chat" -> openChat()
                                    "notes" -> openFiles("notes")
                                    "code" -> openFiles("code")
                                    else -> showMessage("No native renderer for ${view.getString("title")}")
                                }
                            }
                        }
                    })
                }
            }
        }
    } }

    private fun openMcpTools(pluginId: String, refresh: Boolean = false) {
        val encoded = encode(pluginId)
        val method = if (refresh) "POST" else "GET"
        val path = if (refresh) "/api/plugins/$encoded/mcp-tools/refresh" else "/api/plugins/$encoded/mcp-tools"
        requestJson(method, path, if (refresh) JSONObject() else null) { consent ->
            val tools = consent.optJSONArray("discoveredTools") ?: JSONArray()
            val approved = mutableSetOf<String>()
            val approvedJson = consent.optJSONArray("approvedTools") ?: JSONArray()
            for (index in 0 until approvedJson.length()) approved.add(approvedJson.getString(index))
            show { panel ->
                panel.addView(title("MCP tools"))
                panel.addView(text("Discovered tools stay unavailable to AI until you approve them for this Workspace."))
                panel.addView(Button(this).apply {
                    text = "Discover"
                    setOnClickListener { openMcpTools(pluginId, refresh = true) }
                })
                if (tools.length() == 0) panel.addView(text("No tool catalog has been stored yet."))
                for (index in 0 until tools.length()) {
                    val tool = tools.getJSONObject(index)
                    val name = tool.getString("name")
                    panel.addView(CheckBox(this).apply {
                        text = if (tool.optBoolean("approved")) name else "$name · Waiting for approval"
                        isChecked = tool.optBoolean("approved")
                        setOnCheckedChangeListener { _, checked ->
                            if (checked) approved.add(name) else approved.remove(name)
                            val body = JSONObject().put("approvedTools", JSONArray(approved.sorted()))
                            requestJson("POST", "/api/plugins/$encoded/mcp-tools/consent", body) {}
                        }
                    })
                    tool.optString("description").takeIf { it.isNotBlank() }?.let { panel.addView(text(it)) }
                }
                panel.addView(Button(this).apply { text = "Back"; setOnClickListener { loadPlugins() } })
            }
        }
    }

    private fun openApprovals(): Unit { request("/api/agent/approvals?status=pending&limit=50") { response ->
        val approvals = response.optJSONArray("approvals") ?: JSONArray()
        show { panel ->
            panel.addView(title("Pending approvals"))
            if (approvals.length() == 0) panel.addView(text("No pending approvals."))
            for (index in 0 until approvals.length()) {
                val approval = approvals.getJSONObject(index)
                panel.addView(Button(this).apply {
                    text = approval.optString("summary", approval.optString("category", "Approval"))
                    setOnClickListener { openApproval(approval.getString("id")) }
                })
            }
            panel.addView(Button(this).apply { text = "Back"; setOnClickListener { loadPlugins() } })
        }
    } }

    private fun openApproval(id: String): Unit { request("/api/agent/approvals/${encode(id)}") { approval ->
        val diffRef = approval.optString("diffRef")
        if (diffRef.isBlank()) renderApproval(approval, null)
        else request("/api/file?path=${encode(diffRef)}") { file ->
            renderApproval(approval, file.optString("content"))
        }
    } }

    private fun renderApproval(approval: JSONObject, diffText: String?) {
        show { panel ->
            panel.addView(title(approval.optString("summary", "Approval")))
            panel.addView(text(approval.optString("category", "approval")))
            approval.optString("reason").takeIf { it.isNotBlank() }?.let { panel.addView(text(it)) }
            diffText?.takeIf { it.isNotBlank() }?.let {
                panel.addView(title("Proposed diff"))
                panel.addView(text(it).apply {
                    typeface = android.graphics.Typeface.MONOSPACE
                    setTextIsSelectable(true)
                })
            }
            val runChecks = CheckBox(this).apply {
                text = "Run checks after applying patch"
                visibility = if (approval.optString("category") == "code.patch.apply") android.view.View.VISIBLE else android.view.View.GONE
            }
            panel.addView(runChecks)
            panel.addView(Button(this).apply {
                text = "Approve & execute"
                setOnClickListener {
                    val checks = runChecks.isChecked
                    requestJson(
                        "POST",
                        "/api/agent/approvals/${encode(approval.getString("id"))}/respond",
                        JSONObject().put("approved", true).put("runChecksAfterApply", checks).put("checksApproved", checks)
                    ) { openApprovals() }
                }
            })
            panel.addView(Button(this).apply {
                text = "Reject"
                setOnClickListener {
                    requestJson(
                        "POST",
                        "/api/agent/approvals/${encode(approval.getString("id"))}/respond",
                        JSONObject().put("approved", false).put("reason", "Rejected in Android client.")
                    ) { openApprovals() }
                }
            })
            panel.addView(Button(this).apply { text = "Back"; setOnClickListener { openApprovals() } })
        }
    }

    private fun openFiles(root: String) {
        val folder = if (root.equals("code", true)) "Code" else "Notes"
        val scope = documentScope(); val url = server.text.toString().trimEnd('/'); val auth = token.text.toString().trim(); val profile = activeProfileId
        val policies = WorkspaceStoragePolicies(url, profile, File(filesDir, "Documents-v2"))
        thread {
            var online = true
            val manifest = try {
                http.newCall(Request.Builder().url("$url/api/sync/manifest").header("Authorization", "Bearer $auth").build()).execute().use { response ->
                    check(response.isSuccessful); JSONObject(response.body!!.string()).also { policies.cacheCatalog(it) }
                }
            } catch (_: Exception) { online = false; policies.cachedCatalog() }
            runOnUiThread {
                if (documentScope() != scope) return@runOnUiThread
                if (manifest == null) { showMessage("저장된 파일 목록이 없습니다. 서버에 먼저 연결하세요."); return@runOnUiThread }
                val queued = mutableListOf<Triple<String, TextView, LinearLayout>>()
                val entries = manifest.getJSONArray("entries")
                show { panel ->
                    panel.addView(title(folder))
                    if (!online) panel.addView(text("▱ ☁̸ 오프라인 · 이 기기에 저장된 자료만 열 수 있습니다"))
                    panel.addView(storageModeButton(folder, policies))
                    for (item in (0 until entries.length()).map { entries.getJSONObject(it) }.sortedBy { it.getString("path") }) {
                        val path = item.getString("path"); val resource = item.getString("resource")
                        if (!path.startsWith("$folder/") || resource == "annotations") continue
                        if (resource == "file" && online) {
                            val journal = synchronized(documents) { documents.getOrPut("$scope|$path|file") { VersionedDocument(http, url, auth, profile, path, "file", deviceId(), File(filesDir, "Documents-v2")) } }
                            journal.adoptIdenticalEntry(item)
                        }
                        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
                        row.addView(Button(this).apply {
                            text = (if (resource == "folder") "📁 " else "") + path; isEnabled = resource != "folder"
                            setOnClickListener { if (path.endsWith(".pdf", true)) openPdf(path, folder) else openFile(path, folder) }
                        }, LinearLayout.LayoutParams(0, -2, 1f))
                        row.addView(storageModeButton(path, policies))
                        val status = text(if (online) "목록 확인됨" else "오프라인"); row.addView(status)
                        row.addView(android.widget.ProgressBar(this, null, android.R.attr.progressBarStyleSmall).apply { isIndeterminate = true; visibility = android.view.View.GONE }, LinearLayout.LayoutParams(dp(24), dp(24)))
                        panel.addView(row)
                        if (resource == "file") queued.add(Triple(path, status, row))
                    }
                    panel.addView(Button(this).apply { text = "Back"; setOnClickListener { loadPlugins() } })
                }
                // Metadata is visible first; payloads run one at a time, not in the UI thread.
                if (online) thread {
                    for ((path, status, row) in queued) {
                        if (documentScope() != scope) break
                        val journal = synchronized(documents) { documents.getOrPut("$scope|$path|file") { VersionedDocument(http, url, auth, profile, path, "file", deviceId(), File(filesDir, "Documents-v2")) } }
                        if (policies.mode(path) != "sync") {
                            val identity = (0 until entries.length()).map { entries.getJSONObject(it) }.firstOrNull { it.optString("path") == path && it.optString("resource") == "file" }?.optString("fileId")?.takeIf { it.isNotEmpty() }
                            try { journal.evictIfClean(); journal.reportPolicy(identity) } catch (_: Exception) { }
                            runOnUiThread { if (row.parent != null) status.text = "이 기기: ${policies.mode(path)}" }; continue
                        }
                        val busy = row.getChildAt(row.childCount - 1)
                        runOnUiThread { if (row.parent != null) { status.text = "다운로드 중"; busy.visibility = android.view.View.VISIBLE } }
                        try {
                            journal.open(); journal.reportPolicy()
                            runOnUiThread { if (documentScope() == scope && row.parent != null) status.text = "동기화됨" }
                        } catch (error: FirstRegistrationConflict) {
                            runOnUiThread { if (documentScope() == scope && row.parent != null) { status.text = "⚠ 확인 필요"; status.setOnClickListener { askFileConflict(journal) } } }
                        } catch (error: Exception) { runOnUiThread { if (row.parent != null) status.text = "⏸ ${error.message}" } }
                        finally { runOnUiThread { busy.visibility = android.view.View.GONE } }
                    }
                }
            }
        }
    }
    private fun storageModeButton(path: String, policies: WorkspaceStoragePolicies): Button = Button(this).apply {
        fun label() = when (policies.mode(path)) { "local" -> "▱"; "server" -> "☁"; else -> "⇄" }
        text = label(); contentDescription = "이 기기의 저장 모드"
        setOnClickListener {
            android.widget.PopupMenu(this@MainActivity, this).apply {
                listOf("로컬", "서버", "동기화", "상위 설정 따르기").forEach { menu.add(it) }
                setOnMenuItemClickListener { item ->
                    policies.set(path, when (item.title) { "로컬" -> "local"; "서버" -> "server"; "동기화" -> "sync"; else -> null }); text = label()
                    val journal = synchronized(documents) { documents["${documentScope()}|$path|file"] }
                    journal?.evictIfClean(); if (journal != null) thread { try { journal.reportPolicy() } catch (_: Exception) { } }; true
                }; show()
            }
        }
    }
    private fun askFileConflict(journal: VersionedDocument) {
        android.app.AlertDialog.Builder(this).setTitle("서버에 같은 경로의 다른 파일이 있습니다")
            .setMessage("로컬 변경은 결정 전까지 보존됩니다. 서버 덮어쓰기는 다른 기기에도 반영됩니다.")
            .setPositiveButton("서버 버전 사용") { _, _ -> thread { try { journal.resolveFirstConflict(true); journal.flush() } catch (error: Exception) { runOnUiThread { showMessage(error.message ?: "다시 확인하세요") } } } }
            .setNegativeButton("내 버전으로 덮어쓰기") { _, _ -> thread { try { journal.resolveFirstConflict(false); journal.flush() } catch (error: Exception) { runOnUiThread { showMessage(error.message ?: "다시 확인하세요") } } } }
            .setNeutralButton("나중에 결정", null).show()
    }

    private fun openPdf(path: String, root: String) {
        if (WorkspaceStoragePolicies(server.text.toString(), activeProfileId, File(filesDir, "Documents-v2")).mode(path) == "local") { showMessage("Android 로컬 PDF 렌더링은 아직 지원하지 않습니다. 서버 모드로 열거나 Apple 클라이언트를 사용하세요. 로컬 자료는 보존됩니다."); return }
        openServerPdf(path, root)
    }
    private fun openServerPdf(path: String, root: String): Unit { request("/api/pdf/metadata?path=${encode(path)}") { metadata ->
        openVersionedDocument(path, "annotations") { journal, data ->
            val annotations = JSONObject(data.toString(Charsets.UTF_8))
            VersionedDocument.ensurePageIds(annotations)
            var pageIndex = 0
            val pageCount = metadata.optInt("pageCount", 1).coerceAtLeast(1)
            show { panel ->
                val heading = title("")
                val viewer = PdfAnnotationView(this)
                val status = text("Local document ready")
                val handler = Handler(Looper.getMainLooper())
                val scope = documentScope()
                fun saveLocal() {
                    val doc = viewer.annotationDocument()
                    if (!doc.has("pages")) return
                    try { VersionedDocument.ensurePageIds(doc); journal.save(doc.toString().toByteArray()); localEditorSaveFailed = false; status.text = "Locally saved · synchronization pending" }
                    catch (error: Exception) { localEditorSaveFailed = true; status.text = "Not saved: ${error.message}" }
                }
                val sync = Runnable { synchronizeDocument(journal, scope, status, { viewer.annotationDocument().toString().toByteArray() }) { viewer.updateDocument(JSONObject(it.toString(Charsets.UTF_8))) } }
                viewer.onDocumentChanged = { saveLocal(); handler.removeCallbacks(sync); handler.postDelayed(sync, 600) }
                viewer.onEditingStarted = { journal.pinDraft() }
                flushLocalEditor = { handler.removeCallbacks(sync); saveLocal() }
                syncCurrentEditor = { sync.run() }
                val tools = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
                val undo = Button(this).apply { text = "‹"; contentDescription = "Undo"; isEnabled = false; setOnClickListener { viewer.undo() } }
                val redo = Button(this).apply { text = "›"; contentDescription = "Redo"; isEnabled = false; setOnClickListener { viewer.redo() } }
                viewer.onUndoStateChanged = { undo.isEnabled = viewer.canUndo; redo.isEnabled = viewer.canRedo }
                tools.addView(undo); tools.addView(redo)
                fun loadPage() {
                    heading.text = "${path.substringAfterLast('/')} · ${pageIndex + 1}/$pageCount"
                    requestBytes("/api/pdf-thumbnail?path=${encode(path)}&page=${pageIndex + 1}&scale=2") { data ->
                        val bitmap = BitmapFactory.decodeByteArray(data, 0, data.size)
                        if (bitmap == null) status.text = "Could not decode PDF page." else viewer.setPage(bitmap, if (viewer.annotationDocument().has("pages")) viewer.annotationDocument() else annotations, pageIndex)
                    }
                }
                viewer.onTextRequested = { x, y ->
                    val input = EditText(this).apply { hint = "Annotation text" }
                    AlertDialog.Builder(this).setTitle("Add text").setView(input)
                        .setPositiveButton("Add") { _, _ -> viewer.addText(x, y, input.text.toString()) }
                        .setNegativeButton("Cancel", null).show()
                }
                panel.addView(heading)
                panel.addView(viewer, LinearLayout.LayoutParams(-1, 0, 1f))
                panel.addView(status)
                fun toolButton(label: String, tool: PdfAnnotationView.Tool) = Button(this).apply {
                    text = label
                    setOnClickListener { viewer.tool = tool }
                }
                tools.addView(toolButton("Pen", PdfAnnotationView.Tool.PEN))
                tools.addView(toolButton("Rectangle", PdfAnnotationView.Tool.RECTANGLE))
                tools.addView(toolButton("Text", PdfAnnotationView.Tool.TEXT))
                panel.addView(tools)
                val navigation = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
                navigation.addView(Button(this).apply { text = "Previous"; setOnClickListener { if (pageIndex > 0) { pageIndex--; loadPage() } } })
                navigation.addView(Button(this).apply { text = "Next"; setOnClickListener { if (pageIndex + 1 < pageCount) { pageIndex++; loadPage() } } })
                navigation.addView(Button(this).apply {
                    text = "Retry sync"
                    setOnClickListener {
                        saveLocal(); sync.run()
                    }
                })
                panel.addView(navigation)
                panel.addView(Button(this).apply { text = "Back"; setOnClickListener { openFiles(root) } })
                loadPage()
            }
        }
    } }

    private fun openFile(path: String, root: String): Unit { openVersionedDocument(path, "file") { journal, data ->
        show { panel ->
            panel.addView(title(path.substringAfterLast('/')))
            val editor = EditText(this).apply {
                setText(data.toString(Charsets.UTF_8))
                gravity = android.view.Gravity.TOP
                minLines = 18
                setHorizontallyScrolling(true)
            }
            panel.addView(editor, LinearLayout.LayoutParams(-1, 0, 1f))
            val status = text("Local document ready"); panel.addView(status)
            val history = EditHistory()
            var applyingUndo = false
            var remoteUpdate = false
            val undo = Button(this).apply { text = "‹"; contentDescription = "Undo"; isEnabled = false }
            val redo = Button(this).apply { text = "›"; contentDescription = "Redo"; isEnabled = false }
            fun updateUndo() { undo.isEnabled = history.canUndo; redo.isEnabled = history.canRedo }
            fun applyUndo(value: String?) { if (value == null) return; applyingUndo = true; val cursor = editor.selectionStart.coerceAtLeast(0); editor.setText(value); editor.setSelection(cursor.coerceAtMost(value.length)); applyingUndo = false; updateUndo() }
            undo.setOnClickListener { applyUndo(history.undo(editor.text.toString())) }; redo.setOnClickListener { applyUndo(history.redo(editor.text.toString())) }
            panel.addView(LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; addView(undo); addView(redo) })
            val scope = documentScope()
            val handler = Handler(Looper.getMainLooper())
            var editTime = System.currentTimeMillis()
            fun saveLocal() {
                try { journal.save(editor.text.toString().toByteArray(), editTime); localEditorSaveFailed = false; status.text = "Locally saved · synchronization pending" }
                catch (error: Exception) { localEditorSaveFailed = true; status.text = "Not saved: ${error.message}" }
            }
            val autosave = Runnable { saveLocal(); synchronizeDocument(journal, scope, status, { editor.text.toString().toByteArray() }) { val merged = it.toString(Charsets.UTF_8); if (editor.text.toString() != merged) { remoteUpdate = true; editor.setText(merged); remoteUpdate = false; history.clear(); updateUndo() } } }
            editor.addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) { if (!applyingUndo && !remoteUpdate) history.record(s?.toString() ?: "", groupTyping = true) }
                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) { updateUndo(); if (remoteUpdate) return; journal.pinDraft(); editTime = System.currentTimeMillis(); handler.removeCallbacks(autosave); handler.postDelayed(autosave, 600); status.text = "Autosaving…" }
                override fun afterTextChanged(s: Editable?) {}
            })
            flushLocalEditor = { handler.removeCallbacks(autosave); saveLocal() }
            syncCurrentEditor = { autosave.run() }
            panel.addView(Button(this).apply {
                text = "Retry sync"
                setOnClickListener {
                    handler.removeCallbacks(autosave); autosave.run()
                }
            })
            panel.addView(Button(this).apply { text = "Back"; setOnClickListener { openFiles(root) } })
        }
    } }

    private fun openChat() {
        disconnectChat()
        show { panel ->
            panel.addView(title("Chat"))
            transcript = text("Connecting…").also {
                it.setTextIsSelectable(true)
                panel.addView(it, LinearLayout.LayoutParams(-1, 0, 1f))
            }
            val composer = EditText(this).apply { hint = "Message" }
            panel.addView(composer)
            panel.addView(Button(this).apply {
                text = "Send"
                setOnClickListener {
                    val message = composer.text.toString().trim()
                    if (message.isNotEmpty()) {
                        appendChat("You: $message")
                        composer.text.clear()
                        submitChat(message)
                    }
                }
            })
            panel.addView(Button(this).apply { text = "Back"; setOnClickListener { disconnectChat(); loadPlugins() } })
        }
        val wsBase = server.text.toString().trimEnd('/').replaceFirst("https://", "wss://").replaceFirst("http://", "ws://")
        val tokenQuery = token.text.toString().trim().takeIf { it.isNotEmpty() }?.let { "?token=${encode(it)}" } ?: ""
        liveSocket = http.newWebSocket(Request.Builder().url("$wsBase/api/live$tokenQuery").build(), object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                webSocket.send(command("connect", "connect", JSONObject()).toString())
            }

            override fun onMessage(webSocket: WebSocket, value: String) {
                val envelope = JSONObject(value)
                when {
                    envelope.optString("kind") == "result" && envelope.optString("id") == "connect" ->
                        webSocket.send(command("create", "session.create", JSONObject().put("accessMode", "confirm").put("surface", "chat")).toString())
                    envelope.optString("kind") == "result" && envelope.optString("id") == "create" -> {
                        liveSessionId = envelope.optJSONObject("result")?.optString("sessionId")
                        runOnUiThread { appendChat("Connected") }
                        pendingChatMessage?.also { pendingChatMessage = null; submitChat(it) }
                    }
                    envelope.optString("kind") == "runtime.event" || envelope.optString("kind") == "hermes.event" -> {
                        val type = envelope.optString("type")
                        val eventText = envelope.optString("text")
                        if (eventText.isNotBlank() && (type.contains("delta") || type.contains("message"))) {
                            runOnUiThread { appendChat("Codmes: $eventText") }
                        }
                    }
                    envelope.optString("kind") == "error" -> runOnUiThread { appendChat("Error: ${envelope.optString("error")}") }
                }
            }

            override fun onFailure(webSocket: WebSocket, error: Throwable, response: Response?) {
                runOnUiThread { appendChat("Connection failed: ${error.message}") }
            }
        })
    }

    private fun submitChat(message: String) {
        val sessionId = liveSessionId
        if (sessionId == null) { pendingChatMessage = message; return }
        val params = JSONObject().put("sessionId", sessionId).put("message", message).put("surface", "chat")
        liveSocket?.send(command("prompt-${System.nanoTime()}", "prompt.submit", params).toString())
    }

    private fun command(id: String, name: String, params: JSONObject) = JSONObject().put("id", id).put("command", name).put("params", params)
    private fun appendChat(value: String) { transcript?.append("\n$value") }
    private fun disconnectChat() { liveSocket?.close(1000, "leaving chat"); liveSocket = null; liveSessionId = null; pendingChatMessage = null; transcript = null }

    private fun loadSurface(pluginId: String): Unit { request("/api/plugins/${encode(pluginId)}/view-document") { document ->
        show { panel ->
            panel.addView(title(document.optString("title", pluginId)))
            document.optString("subtitle").takeIf { it.isNotBlank() }?.let { panel.addView(text(it)) }
            val items = document.optJSONArray("items") ?: JSONArray()
            val usesCards = document.optString("collectionStyle") == "cards"
            for (index in 0 until items.length()) {
                val item = items.getJSONObject(index)
                if (usesCards) panel.addView(surfaceCard(item))
                else {
                    panel.addView(title(item.optString("title")))
                    item.optString("subtitle").takeIf { it.isNotBlank() }?.let { panel.addView(text(it)) }
                    item.optString("body").takeIf { it.isNotBlank() }?.let { panel.addView(text(it)) }
                }
            }
            val sections = document.optJSONArray("sections") ?: JSONArray()
            for (index in 0 until sections.length()) panel.addView(title(sections.getJSONObject(index).optString("title")))
            panel.addView(Button(this).apply { text = "Back"; setOnClickListener { loadPlugins() } })
        }
    } }

    private fun supportsCurrentDevice(plugin: JSONObject): Boolean {
        return ClientCompatibility.supports(
            declaredPlatforms = strings(plugin.optJSONArray("platforms")),
            declaredFormFactors = strings(plugin.optJSONArray("formFactors")),
            currentPlatform = "android",
            currentFormFactor = formFactor
        )
    }

    private fun strings(values: JSONArray?): List<String> = (0 until (values?.length() ?: 0)).map {
        values!!.getString(it).lowercase()
    }

    private fun documentScope() = server.text.toString().trimEnd('/') + "|" + activeProfileId
    private fun openVersionedDocument(path: String, resource: String, done: (VersionedDocument, ByteArray) -> Unit) {
        val scope = documentScope()
        try {
            check(activeProfileId.isNotEmpty() && token.text.toString().isNotBlank()) { "Connect to a server account first" }
            val url = server.text.toString().trimEnd('/')
            check(accountServerURL.isEmpty() || accountServerURL == url) { "Reconnect after changing the server address" }
            val journal = documents.getOrPut("$scope|$path|$resource") { VersionedDocument(http, url, token.text.toString().trim(), activeProfileId, path, resource, deviceId(), File(filesDir, "Documents-v2")) }
            journal.updateAuth(token.text.toString().trim())
            thread {
                try { val data = journal.open(); runOnUiThread { if (documentScope() == scope) done(journal, data) } }
                catch (error: Exception) { runOnUiThread { if (documentScope() == scope) showMessage(error.message ?: "Document load failed") } }
            }
        } catch (error: Exception) { showMessage(error.message ?: "Document load failed") }
    }
    private fun synchronizeDocument(journal: VersionedDocument, scope: String, status: TextView, snapshot: () -> ByteArray, merged: (ByteArray) -> Unit) {
        if (documentScope() != scope) return;
        val before = snapshot()
        thread {
            try {
                journal.flush(); val data = journal.open()
                runOnUiThread {
                    if (documentScope() == scope) {
                        if (snapshot().contentEquals(before) && journal.pendingCount() == 0) merged(data)
                        status.text = if (journal.pendingCount() == 0) "Server synchronized" else "Locally saved · synchronization pending"
                    }
                }
            } catch (error: Exception) { runOnUiThread { if (documentScope() == scope) status.text = error.message ?: "Locally saved · synchronization pending" } }
        }
    }
    private fun request(path: String, done: (JSONObject) -> Unit) = requestJson("GET", path, null, done)

    private fun requestBytes(path: String, done: (ByteArray) -> Unit) = thread {
        try {
            val builder = Request.Builder().url(server.text.toString().trimEnd('/') + path)
            token.text.toString().trim().takeIf { it.isNotEmpty() }?.let { builder.header("Authorization", "Bearer $it") }
            val response = http.newCall(builder.build()).execute()
            val data = response.body?.bytes() ?: ByteArray(0)
            if (!response.isSuccessful) error("Workspace returned ${response.code}")
            runOnUiThread { done(data) }
        } catch (error: Exception) {
            runOnUiThread { showMessage(error.message ?: "Download failed") }
        }
    }

    private fun requestJson(method: String, path: String, body: JSONObject?, done: (JSONObject) -> Unit) =
        requestJson(method, path, body, done, null)

    private fun requestJson(method: String, path: String, body: JSONObject?, done: (JSONObject) -> Unit, authOverride: String?): Thread {
        val serverUrl = server.text.toString().trimEnd('/')
        val auth = authOverride ?: token.text.toString().trim()
        return thread {
            try {
                if (auth.isNotEmpty() && accountServerURL.isNotEmpty() && accountServerURL != serverUrl)
                    error("The server address changed. Connect to the selected server again.")
                val uri = Uri.parse(serverUrl)
                if (path != "/api/google-auth/config" && uri.scheme != "https" && !(uri.scheme == "http" && uri.host in setOf("127.0.0.1","localhost","::1"))) error("Remote account access requires HTTPS.")
                val builder = Request.Builder().url(serverUrl + path).header("Accept", "application/json")
                auth.takeIf { it.isNotEmpty() }?.let { builder.header("Authorization", "Bearer $it") }
                val requestBody = body?.toString()?.toRequestBody("application/json".toMediaType())
                builder.method(method, if (method == "GET") null else requestBody ?: ByteArray(0).toRequestBody())
                val response = http.newCall(builder.build()).execute()
                val responseText = response.body?.string().orEmpty()
                if (!response.isSuccessful) error("Workspace returned ${response.code}: $responseText")
                val json = if (responseText.isBlank()) JSONObject() else JSONObject(responseText)
                runOnUiThread { if (server.text.toString().trimEnd('/') == serverUrl) done(json) }
            } catch (error: Exception) {
                runOnUiThread { if (server.text.toString().trimEnd('/') == serverUrl) showMessage(error.message ?: "Connection failed") }
            }
        }
    }

    override fun onDestroy() { flushLocalEditor?.invoke(); reconnectHandler.removeCallbacks(reconnect); disconnectChat(); super.onDestroy() }

    private fun show(build: (LinearLayout) -> Unit) { flushLocalEditor?.invoke(); if (localEditorSaveFailed) return; flushLocalEditor = null; syncCurrentEditor = null; content.removeAllViews(); build(content) }
    private fun showMessage(message: String) = show { it.addView(text(message)) }
    private fun title(value: String) = TextView(this).apply { text = value; textSize = 20f; setPadding(0, 18, 0, 8) }
    private fun text(value: String) = TextView(this).apply { text = value; textSize = 15f; setPadding(0, 4, 0, 8) }
    private fun surfaceCard(item: JSONObject) = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(16), dp(14), dp(16), dp(14))
        background = GradientDrawable().apply {
            setColor(Color.rgb(250, 250, 250))
            setStroke(dp(1), Color.rgb(218, 218, 218))
            cornerRadius = dp(14).toFloat()
        }
        layoutParams = LinearLayout.LayoutParams(-1, -2).apply { setMargins(0, dp(6), 0, dp(6)) }

        val context = listOfNotNull(
            item.optString("systemImage").takeIf { it.isNotBlank() }?.let(::surfaceSymbol),
            item.optString("eyebrow").takeIf { it.isNotBlank() }
        ).joinToString(" ")
        if (context.isNotBlank()) addView(text(context).apply {
            setTextColor(Color.rgb(30, 100, 210)); textSize = 13f; setTypeface(null, Typeface.BOLD)
        })
        item.optString("badge").takeIf { it.isNotBlank() }?.let { value ->
            addView(text(value).apply {
                setTextColor(surfaceTone(item.optString("badgeTone")))
                textSize = 12f; setTypeface(null, Typeface.BOLD)
            })
        }
        item.optString("meta").takeIf { it.isNotBlank() }?.let { addView(text(it).apply { textSize = 12f }) }
        addView(title(item.optString("title")).apply { textSize = 18f })
        item.optString("subtitle").takeIf { it.isNotBlank() }?.let { addView(text(it)) }
        item.optString("body").takeIf { it.isNotBlank() }?.let { addView(text(it)) }
    }
    private fun surfaceTone(value: String) = when (value) {
        "danger" -> Color.rgb(190, 35, 45)
        "warning" -> Color.rgb(180, 105, 0)
        "success" -> Color.rgb(20, 125, 65)
        "neutral" -> Color.DKGRAY
        else -> Color.rgb(30, 100, 210)
    }
    private fun surfaceSymbol(value: String) = when (value) {
        "bell" -> "🔔"
        "calendar" -> "📅"
        "checkmark.circle" -> "✓"
        else -> ""
    }
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
    private fun encode(value: String) = java.net.URLEncoder.encode(value, Charsets.UTF_8.name())
}
