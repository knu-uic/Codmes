import { invoke } from "@tauri-apps/api/core";
import { ReadinessCancelledError, ReadinessTimeoutError, waitForReadiness } from "./auth-readiness";
import { confirmGoogleAccountChange } from "./account-confirmation";
import { existingServerChoice, resetWarning, resetConfirmationFields, resetConfirmed, type ServerSetup } from "./server-start";
import "./styles.css";
import "./profiles.css";
import "./auth.css";

type ServerSettings={workspaceRoot:string;host:string;port:number;postgresPort:number;startOnLaunch:boolean;launchAtLogin:boolean;showDockIcon:boolean;tlsCertPath:string;tlsKeyPath:string};
type ServerStatus={running:boolean;managed:boolean;pid:number|null;url:string;workspaceRoot:string;startedAt:number|null;message:string};
type Snapshot={settings:ServerSettings;status:ServerStatus;logs:string[];runtimeReady:boolean;runtimeMessage:string};
type ManagedProfile={id:string;name:string;locked:boolean;deleted:boolean;ownerName:string};
type ManagedPlugin={id:string;name:string;version:string;installed:boolean;installedVersion:string|null;updateAvailable:boolean;blocked:boolean;permissionChangeRequired:boolean;addedPermissions:string[]};
type GoogleConfig={enabled:boolean;clientIds:{desktop:string;macos:string;ios:string;android:string;web:string};bootstrapRequired:boolean;adminLinked:boolean;approvalMode:"ask"|"allow";requiresSecureTransport:boolean};
type OAuthConfig={configured:boolean};
type AccountUser={id:string;username:string;displayName:string;email:string;googleLinked:boolean;credentialsConfigured:boolean};
type ClientRegistration={id:string;username:string;email:string;displayName:string;deviceName:string;status:string;createdAt:string};

let snapshot:Snapshot; let active="dashboard"; let busy=false; let managerSignedIn=false; let managerIdentity="";
let authGeneration=0; let managerAccount:AccountUser|undefined;
let authStage:"choice"|"login"|"fresh"="choice";
const app=document.querySelector<HTMLDivElement>("#app")!;
const h=(value:unknown)=>String(value??"").replace(/[&<>'"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"}[c]!));
const err=(error:unknown)=>error instanceof Error?error.message:String(error);
function toast(message:string,error=false){const el=document.createElement("div");el.className=`toast ${error?"bad":""}`;el.textContent=message;document.body.append(el);setTimeout(()=>el.remove(),3200)}

function shell(){app.innerHTML=`<aside><div class="brand"><span class="mark">C</span><div><strong>Codmes Server</strong><small>Workspace Manager</small></div></div><nav>${[["dashboard","대시보드"],["clients","클라이언트 승인"],["account","관리자 계정"],["profiles","프로필 관리"],["plugins","플러그인"],["settings","서버 설정"],["logs","서버 로그"]].map(([id,label],i)=>`<button data-tab="${id}" class="${i?'':'active'}">${label}</button>`).join('')}</nav><div class="aside-foot"><span id="dot" class="dot"></span><span id="aside-state">확인 중</span></div></aside><main><header><div><h1 id="title">대시보드</h1><p id="subtitle">Workspace 서버 상태를 관리합니다.</p></div><button id="refresh" class="ghost">새로고침</button></header><section id="view"></section></main>`;document.querySelectorAll<HTMLButtonElement>("nav button").forEach(button=>button.onclick=()=>openTab(button.dataset.tab!));document.querySelector<HTMLButtonElement>("#refresh")!.onclick=()=>openTab(active)}
const titles:Record<string,[string,string]>={dashboard:["대시보드","Workspace 서버를 시작하고 모든 Codmes 클라이언트의 연결 상태를 확인합니다."],clients:["클라이언트 승인","로그인한 기기의 접속을 수락하거나 거절합니다."],account:["관리자 계정","Codmes 관리자 계정과 Google 연결을 관리합니다."],profiles:["프로필 관리","Codmes 계정별 프로필의 이름 변경과 보관·복구를 관리합니다."],plugins:["플러그인","서버 공용 플러그인을 한 번 설치·업데이트합니다."],settings:["서버 설정","네트워크 연결, 실행 방식과 macOS 표시 방식을 설정합니다."],logs:["서버 로그","Workspace 서버의 최근 출력을 확인합니다."]};
async function getSnapshot(){snapshot=await invoke<Snapshot>("manager_snapshot");document.querySelector("#dot")?.classList.toggle("on",snapshot.status.running);const state=document.querySelector("#aside-state");if(state)state.textContent=snapshot.status.running?"서버 실행 중":"서버 중지됨"}
async function openTab(id:string){if(!managerSignedIn){await renderAuth();return}active=id;document.querySelectorAll("nav button").forEach(button=>button.classList.toggle("active",(button as HTMLButtonElement).dataset.tab===id));const [title,subtitle]=titles[id];document.querySelector("#title")!.textContent=title;document.querySelector("#subtitle")!.textContent=subtitle;document.querySelector("#view")!.innerHTML='<div class="loading">불러오는 중…</div>';try{await getSnapshot();await ({dashboard,clients,account,profiles,plugins,settings,logs} as Record<string,()=>Promise<void>>)[id]()}catch(error){document.querySelector("#view")!.innerHTML=`<div class="empty error">${h(err(error))}</div>`}}
async function operation(command:string,message:string){if(busy)return;busy=true;try{await invoke(command);await new Promise(resolve=>setTimeout(resolve,350));toast(message);await openTab(active)}catch(error){toast(err(error),true)}finally{busy=false}}

async function dashboard(){const s=snapshot;document.querySelector("#view")!.innerHTML=`<div class="hero ${s.status.running?'healthy':''}"><div><span class="eyebrow">SYSTEM STATUS</span><h2>${s.status.running?'정상 실행 중':'서버가 중지되어 있습니다'}</h2><p>${h(s.status.running?s.status.url:s.status.message)}</p></div><button id="power" class="power ${s.status.running?'stop':''}">${s.status.running?'서버 종료':'서버 실행'}</button></div><div class="stats"><article><span>프로세스</span><strong>${s.status.running?'ON':'OFF'}</strong></article><article><span>관리 상태</span><strong>${s.status.managed?'Managed':'External'}</strong></article><article><span>PID</span><strong>${s.status.pid??'—'}</strong></article></div><article class="panel"><div class="list-head"><h3>연결 정보</h3><button id="copy-url" class="ghost">주소 복사</button></div><dl><dt>서버 주소</dt><dd>${h(s.status.url)}</dd><dt>PostgreSQL 포트</dt><dd>${h(s.settings.postgresPort)}</dd><dt>데이터 저장소</dt><dd>${h(s.settings.workspaceRoot)}</dd><dt>Runtime</dt><dd>${h(s.runtimeMessage)}</dd></dl><div class="actions"><button id="restart" class="ghost" ${!s.status.managed?'disabled':''}>재시작</button></div></article>`;document.querySelector<HTMLButtonElement>("#power")!.onclick=()=>operation(s.status.running?"stop_server":"start_server",s.status.running?"서버를 종료했습니다.":"서버를 실행했습니다.");document.querySelector<HTMLButtonElement>("#restart")!.onclick=()=>operation("restart_server","서버를 재시작했습니다.");document.querySelector<HTMLButtonElement>("#copy-url")!.onclick=async()=>{await navigator.clipboard.writeText(s.status.url);toast("서버 주소를 복사했습니다.")}}

function authFrame(title:string,description:string,body:string){
  app.innerHTML=`<div class="auth-stage"><div class="auth-brand"><span class="mark">C</span><strong>Codmes Server Manager</strong></div><article class="auth-card panel"><span class="eyebrow">SERVER MANAGER</span><h1>${title}</h1><p class="muted">${description}</p>${body}<p id="auth-status" class="auth-status" role="status"></p></article></div>`;
}
async function renderAuth(){
  const generation=++authGeneration;
  authFrame("서버를 시작하고 있습니다","서버가 준비되면 로그인 화면으로 자동 이동합니다.",'<div class="auth-loading" role="status"><span class="auth-spinner" aria-hidden="true"></span><span>서버 연결을 확인하는 중…</span></div>');
  try{
    const ready=await waitForReadiness(async()=>{
      const current=await invoke<Snapshot>("manager_snapshot");
      if(!current.status.running||!current.status.managed)return {snapshot:current};
      const oauth=await invoke<OAuthConfig>("manager_google_oauth_config");
      const config=await invoke<GoogleConfig>("manager_google_server_config");
      return {snapshot:current,oauth,config};
    },{isCurrent:()=>generation===authGeneration&&!managerSignedIn});
    snapshot=ready.snapshot;
    if(!snapshot.runtimeReady){
      authFrame("서버 실행 환경을 확인하세요",h(snapshot.runtimeMessage),'<p class="muted">기존 자료는 삭제하지 않았습니다. 문제를 해결한 뒤 앱을 다시 실행하세요.</p><button id="auth-retry" class="ghost">다시 확인</button>');
      document.querySelector<HTMLButtonElement>("#auth-retry")!.onclick=()=>renderAuth();return;
    }
    if(!snapshot.status.running){
      authFrame("서버를 시작하세요","Google 계정으로 Server Manager에 로그인하기 전에 서버가 실행되어야 합니다.",'<button id="auth-start">서버 시작</button>');
      document.querySelector<HTMLButtonElement>("#auth-start")!.onclick=async()=>{if(busy)return;busy=true;const button=document.querySelector<HTMLButtonElement>("#auth-start")!;button.disabled=true;button.textContent="시작 중…";try{await invoke("start_server");await renderAuth()}catch(error){toast(err(error),true);button.disabled=false;button.textContent="서버 시작"}finally{busy=false}};
      return;
    }
    if(!snapshot.status.managed){
      authFrame("서버 연결 확인","현재 주소에 다른 프로세스가 Codmes 서버를 실행 중입니다. 이 Manager에서 시작한 서버에만 관리자 로그인을 허용합니다.",'<button id="auth-retry" class="ghost">다시 확인</button>');
      document.querySelector<HTMLButtonElement>("#auth-retry")!.onclick=()=>renderAuth();return;
    }
    const config=ready.config!;
    const setup=await invoke<ServerSetup>("manager_server_setup");
    if(generation!==authGeneration||managerSignedIn)return;
    if(setup.existingServer===config.bootstrapRequired)throw new Error("서버 계정 상태가 변경되었습니다. 다시 확인해 주세요.");
    if(setup.existingServer&&authStage==="choice"){
      authFrame("기존 서버 데이터가 있습니다","앱을 삭제하거나 재설치해도 서버 데이터는 이 컴퓨터에 남아 있습니다. 이어서 사용하거나 기존 서버를 초기화할 수 있습니다.",existingServerChoice(setup));
      document.querySelector<HTMLButtonElement>("#continue-server")!.onclick=()=>{authStage="login";void renderAuth()};
      document.querySelector<HTMLButtonElement>("#fresh-server")!.onclick=()=>{if(setup.resetAllowed){authStage="fresh";void renderAuth()}};
      return;
    }
    const fresh=setup.existingServer&&authStage==="fresh";
    if(fresh&&!setup.resetAllowed){authStage="choice";await renderAuth();return}
    const signup=config.bootstrapRequired||fresh;
    const hint=h(setup.maskedAccount?.email||setup.maskedAccount?.id||"");
    authFrame(fresh?"새 서버로 시작하기":signup?"관리자 계정 만들기":"기존 관리자 계정 로그인",fresh?"새 관리자 계정 정보를 입력하세요. 명시적 삭제 확인과 이 컴퓨터의 OS 관리자 확인 후 새 서버를 구성합니다.":signup?"이 서버의 첫 Codmes 관리자 계정을 만듭니다. Google은 선택해서 연결할 수 있습니다.":`기존 서버와 자료를 이어서 사용합니다.${hint?` (${hint})`:""}`,
      `${fresh?resetWarning():""}<form id="account-login" class="form">${credentialFields(signup)}${fresh?resetConfirmationFields():""}<button type="submit" ${fresh?'class="danger"':""}>${fresh?"기존 서버 삭제 후 새 계정 만들기":signup?"회원가입":"로그인"}</button></form>
       ${ready.oauth?.configured&&config.enabled?`<div class="actions"><button id="google-login" class="ghost">Google로 ${signup?"가입":"로그인"}</button></div>`:'<p class="muted">Google 로그인이 설정되지 않았습니다. ID·비밀번호 로그인은 사용할 수 있습니다.</p>'}
       ${setup.existingServer?'<button id="auth-back" class="text-button">← 서버 선택으로 돌아가기</button>':""}`);
    document.querySelector<HTMLButtonElement>("#auth-back")?.addEventListener("click",()=>{if(!busy){authStage="choice";void renderAuth()}});
    document.querySelector<HTMLFormElement>("#account-login")!.onsubmit=async event=>{
      event.preventDefault();if(busy)return;
      const payload=readCredentials(signup);if(!payload)return;
      if(fresh){await createFreshServer(payload,false);return}
      busy=true;try{await acceptAccount(await invoke<{user:AccountUser}>("manager_codmes_account",{action:signup?"bootstrap":"login",payload}));toast("관리자로 로그인했습니다.")}catch(error){toast(err(error),true)}finally{busy=false}
    };
    document.querySelector<HTMLButtonElement>("#google-login")?.addEventListener("click",()=>{const payload=signup?readCredentials(true):{};if(payload){if(fresh)void createFreshServer(payload,true);else void signIn(signup?"bootstrap":"login",payload)}});
  }catch(error){
    if(error instanceof ReadinessCancelledError||generation!==authGeneration)return;
    const timedOut=error instanceof ReadinessTimeoutError;
    authFrame(timedOut?"서버 시작을 확인해 주세요":"로그인 화면을 열 수 없습니다",timedOut?"1분 동안 서버 연결을 자동 확인했지만 준비되지 않았습니다. 아래 내용을 확인한 뒤 다시 시도해 주세요.":h(err(error)),`${timedOut?`<details class="auth-error-details"><summary>오류 상세</summary><p>${h(err(error.lastError))}</p></details>`:""}<button id="auth-retry" class="ghost">다시 시도</button>`);
    document.querySelector<HTMLButtonElement>("#auth-retry")!.onclick=()=>renderAuth();
  }
}
async function createFreshServer(payload:Record<string,string>,google:boolean){
  if(busy)return;
  const confirmation=document.querySelector<HTMLInputElement>("#reset-confirmation")!.value;
  const acknowledged=document.querySelector<HTMLInputElement>("#reset-ack")!.checked;
  if(!resetConfirmed(confirmation,acknowledged)){toast("‘기존 서버 삭제’를 정확히 입력하고 삭제 동의에 체크하세요.",true);return}
  busy=true;++authGeneration;
  document.querySelectorAll<HTMLButtonElement>(".auth-card button").forEach(button=>button.disabled=true);
  const status=document.querySelector<HTMLElement>("#auth-status")!;
  status.textContent=google?"Google 인증 후 컴퓨터 관리자 확인 창에서 승인하세요. 새 서버를 준비하는 동안 기다려 주세요.":"컴퓨터 관리자 확인 창에서 승인하세요. 새 서버를 준비하는 동안 기다려 주세요.";
  const pending=document.createElement("div");pending.className="google-sign-in-pending";
  pending.setAttribute("role","status");
  pending.innerHTML='<span>새 서버를 만드는 중… 앱을 종료하지 마세요.</span><button type="button" class="ghost">취소</button>';
  document.body.append(pending);
  pending.querySelector<HTMLButtonElement>("button")!.onclick=async()=>{await invoke("manager_google_cancel_sign_in").catch(error=>toast(err(error),true))};
  try{
    const result=await invoke<{user:AccountUser;resetCleanupWarning?:string|null}>("manager_fresh_start",{...payload,mode:google?"google":"password",confirmation});
    authStage="choice";await acceptAccount(result);
    if(result.resetCleanupWarning){toast("새 서버는 생성되었지만 이전 데이터 정리가 완료되지 않았습니다. 앱을 다시 실행해 정리를 완료하세요.",true);console.error(result.resetCleanupWarning)}
    else toast("기존 서버를 초기화하고 새 관리자 계정을 만들었습니다.");
  }catch(error){status.textContent=err(error);toast(err(error),true)}
  finally{pending.remove();busy=false;document.querySelectorAll<HTMLButtonElement>(".auth-card button").forEach(button=>button.disabled=false)}
}
async function signIn(mode:"bootstrap"|"login"|"change",extras:Record<string,string>={}){
  if(busy)return;busy=true;++authGeneration;const status=document.querySelector<HTMLElement>(mode==="change"?"#account-status":"#auth-status");if(status)status.textContent=mode==="change"?"시스템 브라우저에서 새 관리자 Google 계정을 선택하세요…":"시스템 브라우저에서 Google 계정을 선택하세요…";
  const pending=document.createElement("div");pending.className="google-sign-in-pending";pending.setAttribute("role","status");
  pending.innerHTML='<span>Google 로그인 대기 중… 최대 10분간 기다립니다. 브라우저 창을 닫았다면 로그인 취소를 누르세요.</span><button type="button" class="ghost">로그인 취소</button>';
  document.body.append(pending);
  const cancel=pending.querySelector<HTMLButtonElement>("button")!;
  cancel.onclick=async()=>{cancel.disabled=true;cancel.textContent="취소 중…";try{await invoke("manager_google_cancel_sign_in")}catch(error){toast(err(error),true);cancel.disabled=false;cancel.textContent="로그인 취소"}};
  try{const result=await invoke<{user:AccountUser}>("manager_google_sign_in",{mode,...extras});await acceptAccount(result,mode==="change"?"account":"dashboard");toast(mode==="change"?"Google 연결을 변경했습니다. Codmes 계정과 자료는 유지됩니다.":"관리자로 로그인했습니다.")}
  catch(error){const message=err(error);const cancelled=message.includes("Google sign-in was cancelled.");if(!cancelled)toast(message,true);if(status)status.textContent=cancelled?(mode==="change"?"계정 변경을 취소했습니다. 기존 계정을 유지합니다.":"로그인을 취소했습니다."):message;if(mode==="change"&&!await invoke<boolean>("manager_authenticated").catch(()=>false)){managerSignedIn=false;managerIdentity="";await renderAuth()}}finally{pending.remove();busy=false;document.querySelector<HTMLButtonElement>("#change-google")?.removeAttribute("disabled");document.querySelector<HTMLButtonElement>("#manager-signout")?.removeAttribute("disabled")}
}
function credentialFields(signup:boolean){
  return `<label>Codmes ID<input id="account-id" autocomplete="username" maxlength="64" required placeholder="영문·숫자 등 3~64자"/></label>
  <label>비밀번호<input id="account-password" type="password" autocomplete="${signup?"new-password":"current-password"}" maxlength="128" ${signup?'minlength="15"':''} required/></label>
  ${signup?'<label>비밀번호 확인<input id="account-confirm" type="password" autocomplete="new-password" maxlength="128" required/></label><p class="muted">비밀번호는 15~128자입니다. 여러 단어를 조합해도 됩니다. 이 계정은 이 서버에서만 사용합니다.</p>':''}`;
}
function readCredentials(signup:boolean):Record<string,string>|undefined{
  const username=document.querySelector<HTMLInputElement>("#account-id")!.value.trim();
  const password=document.querySelector<HTMLInputElement>("#account-password")!.value;
  if(!username||!password){toast("ID와 비밀번호를 입력하세요.",true);return}
  if(signup&&(Array.from(password).length<15||password.length>128||password!==document.querySelector<HTMLInputElement>("#account-confirm")!.value)){toast("비밀번호는 15~128자로 입력하고 확인란과 일치해야 합니다.",true);return}
  return {username,password};
}
async function acceptAccount(result:{user:AccountUser},tab="dashboard"){
  managerSignedIn=true;managerAccount=result.user;managerIdentity=result.user.username||result.user.email;
  if(!result.user.credentialsConfigured){await credentialSetup();return}
  shell();await openTab(tab);
}
async function credentialSetup(){
  authFrame("Codmes 계정 설정","기존 Google 계정의 프로필과 자료는 그대로 유지됩니다. 앞으로 Google 없이도 로그인할 ID와 비밀번호를 한 번만 설정하세요.",
    `<form id="credential-setup" class="form">${credentialFields(true)}<button type="submit">계정 설정 완료</button></form><button id="setup-signout" class="ghost">로그아웃</button>`);
  document.querySelector<HTMLButtonElement>("#setup-signout")!.onclick=()=>logoutManager();
  document.querySelector<HTMLFormElement>("#credential-setup")!.onsubmit=async event=>{event.preventDefault();const payload=readCredentials(true);if(!payload||busy)return;busy=true;try{await acceptAccount(await invoke<{user:AccountUser}>("manager_codmes_account",{action:"credentials",payload}));toast("Codmes 계정을 설정했습니다.")}catch(error){toast(err(error),true)}finally{busy=false}};
}
async function logoutManager(){
  try{await invoke("manager_account_logout")}catch(error){toast(err(error),true)}
  managerSignedIn=false;managerIdentity="";managerAccount=undefined;authStage="choice";await renderAuth();
}
async function account(){
  const result=await invoke<{user:AccountUser}>("manager_codmes_account",{action:"info"});
  managerAccount=result.user;
  if(!result.user.credentialsConfigured){await credentialSetup();return}
  const user=result.user;
  document.querySelector("#view")!.innerHTML=`<article class="panel form"><h3>Codmes 관리자 계정</h3><p>ID: ${h(user.username)}</p><p class="muted">Google: ${user.googleLinked?h(user.email):"연결하지 않음"}</p>
    <label>현재 Codmes 비밀번호<input id="current-password" type="password" autocomplete="current-password" maxlength="128"/></label>
    <div class="actions account-actions"><button id="change-google" class="ghost">${user.googleLinked?"Google 연결 변경":"Google 연결"}</button>${user.googleLinked?'<button id="unlink-google" class="ghost">Google 연결 해제</button>':''}<button id="manager-signout">로그아웃</button></div>
    <p class="muted">Google 연결 변경·해제에는 현재 Codmes 비밀번호가 필요합니다. 계정·프로필·기기 승인은 유지되고 다른 로그인 세션은 해제됩니다.</p>
    <label>새 비밀번호<input id="new-password" type="password" autocomplete="new-password" minlength="15" maxlength="128"/></label><label>새 비밀번호 확인<input id="new-confirm" type="password" autocomplete="new-password" maxlength="128"/></label>
    <button id="change-password">비밀번호 변경</button><p id="account-status" class="auth-status" role="status"></p></article>`;
  const currentPassword=()=>document.querySelector<HTMLInputElement>("#current-password")!.value;
  document.querySelector<HTMLButtonElement>("#manager-signout")!.onclick=()=>{if(!busy)void logoutManager()};
  document.querySelector<HTMLButtonElement>("#change-google")!.onclick=async()=>{if(busy)return;if(!currentPassword()){toast("현재 Codmes 비밀번호를 입력하세요.",true);return}if(await confirmGoogleAccountChange())await signIn("change",{currentPassword:currentPassword()})};
  document.querySelector<HTMLButtonElement>("#unlink-google")?.addEventListener("click",async()=>{
    if(busy||!currentPassword()||!await confirmGoogleAccountChange(document,true))return;
    busy=true;try{await invoke("manager_codmes_account",{action:"unlink",payload:{currentPassword:currentPassword()}});toast("Google 연결을 해제했습니다.");await account()}catch(error){toast(err(error),true)}finally{busy=false}
  });
  document.querySelector<HTMLButtonElement>("#change-password")!.onclick=async()=>{
    if(busy)return;const password=document.querySelector<HTMLInputElement>("#new-password")!.value;
    if(!currentPassword()||password.length<15||password!==document.querySelector<HTMLInputElement>("#new-confirm")!.value){toast("현재 비밀번호와 일치하는 새 비밀번호 확인을 입력하세요. 새 비밀번호는 15~128자입니다.",true);return}
    busy=true;try{await invoke("manager_codmes_account",{action:"password",payload:{currentPassword:currentPassword(),password}});toast("비밀번호를 변경했습니다. 다른 기기의 로그인은 해제됩니다.");await account()}catch(error){toast(err(error),true)}finally{busy=false}
  };
}

async function settings(){
  const s=snapshot.settings;
  document.querySelector("#view")!.innerHTML=`<form id="settings-form" class="panel form"><h3>서버 설정</h3><div class="managed-storage"><span>데이터 저장소</span><code>${h(s.workspaceRoot)}</code><small>Notes, Code, 대화, 계정과 검색 DB를 Server가 관리합니다.</small></div><div class="field-row"><label>접속 범위<select id="host"><option value="127.0.0.1">이 컴퓨터만</option><option value="0.0.0.0">같은 네트워크</option></select></label><label>포트<input id="port" type="number" min="1024" max="65535" value="${s.port}"/></label></div><div class="tls-settings"><h3>HTTPS (다른 기기 접속 시 필수)</h3><p class="muted">다른 기기의 Google 로그인은 신뢰 가능한 HTTPS가 있어야 합니다. 인증서에 서버의 LAN 주소와 127.0.0.1이 포함되고 각 클라이언트가 인증서를 신뢰해야 합니다. 인증서가 없으면 원격 Google 로그인은 서버에서 거절합니다.</p><label>TLS 인증서 PEM 절대 경로<input id="tls-cert" value="${h(s.tlsCertPath||"")}" placeholder="/path/to/server-cert.pem"/></label><label>TLS 개인 키 PEM 절대 경로<input id="tls-key" value="${h(s.tlsKeyPath||"")}" placeholder="/path/to/server-key.pem"/></label></div><div class="toggles"><label><input id="start-on-launch" type="checkbox" ${s.startOnLaunch?'checked':''}/> Manager 실행 시 서버 자동 시작</label><label><input id="launch-at-login" type="checkbox" ${s.launchAtLogin?'checked':''}/> 로그인 시 Manager 자동 실행</label><label><input id="show-dock-icon" type="checkbox" ${s.showDockIcon?'checked':''}/> macOS Dock에도 아이콘 표시</label></div><div class="actions"><button type="submit">설정 저장</button></div></form>`;
  const host=document.querySelector<HTMLSelectElement>("#host")!;host.value=s.host;
  document.querySelector<HTMLFormElement>("#settings-form")!.onsubmit=async event=>{
    event.preventDefault();if(busy)return;
    const settings:ServerSettings={workspaceRoot:s.workspaceRoot,host:host.value,port:Number(document.querySelector<HTMLInputElement>("#port")!.value),postgresPort:s.postgresPort,startOnLaunch:document.querySelector<HTMLInputElement>("#start-on-launch")!.checked,launchAtLogin:document.querySelector<HTMLInputElement>("#launch-at-login")!.checked,showDockIcon:document.querySelector<HTMLInputElement>("#show-dock-icon")!.checked,tlsCertPath:document.querySelector<HTMLInputElement>("#tls-cert")!.value.trim(),tlsKeyPath:document.querySelector<HTMLInputElement>("#tls-key")!.value.trim()};
    busy=true;try{await invoke("save_server_settings",{settings});const changed=settings.host!==s.host||settings.port!==s.port||settings.tlsCertPath!==s.tlsCertPath||settings.tlsKeyPath!==s.tlsKeyPath;if(changed&&snapshot.status.managed){await invoke("restart_server");toast("네트워크 설정을 저장하고 서버를 재시작했습니다.")}else toast(snapshot.status.running?"저장했습니다. 나머지 서버 변경은 재시작 후 적용됩니다.":"설정을 저장했습니다.");await openTab("settings")}catch(error){toast(err(error),true)}finally{busy=false}
  };
}
async function logs(){document.querySelector("#view")!.innerHTML=`<article class="panel"><div class="list-head"><h3>최근 로그</h3><button id="refresh-logs" class="ghost">새로고침</button></div><div class="runtime-state ${snapshot.runtimeReady?'ready':'warning'}">${h(snapshot.runtimeMessage)}</div><pre class="logs">${h(snapshot.logs.join('\n')||'아직 로그가 없습니다.')}</pre></article>`;document.querySelector<HTMLButtonElement>("#refresh-logs")!.onclick=()=>openTab("logs")}

void renderAuth();window.setInterval(()=>{if(managerSignedIn)void getSnapshot().catch(()=>{})},3000);

async function clients(){
  const view=document.querySelector<HTMLElement>("#view")!;
  if(!snapshot.status.managed){view.innerHTML='<article class="panel form"><h3>클라이언트 승인</h3><p class="muted">이 Manager에서 서버를 실행한 뒤 관리할 수 있습니다.</p></article>';return}
  const result=await invoke<{mode:"ask"|"allow";registrations:ClientRegistration[]}>("manager_client_registrations");
  const modeLabel=result.mode==="allow"?"상시 허용":"승인 요청";
  const rows=result.registrations.map(registration=>`<article class="panel client-item" data-registration-id="${h(registration.id)}"><div class="list-head"><div><h3>${h(registration.displayName||registration.email||"Google 사용자")}</h3><p class="muted">${h(registration.username||registration.email||"Codmes 계정")} · ${h(registration.deviceName||"이름 없는 기기")}</p><small>${h(registration.createdAt||"")}</small></div><span class="client-status ${h(registration.status)}">${registration.status==="pending"?"승인 대기":registration.status==="approved"?"승인됨":registration.status==="rejected"?"거절됨":h(registration.status)}</span></div><div class="actions">${registration.status==="pending"?'<button data-client-action="approve">수락</button><button class="ghost" data-client-action="reject">거절</button>':''}${registration.status==="approved"||registration.status==="rejected"?'<button class="ghost" data-client-action="remove">등록 삭제</button>':''}</div></article>`).join("");
  view.innerHTML=`<article class="panel form client-mode"><h3>새 클라이언트 승인 방식</h3><p class="muted">승인 요청은 새 로그인/기기를 관리자가 수락해야 합니다. 등록을 삭제하면 해당 기기의 세션도 폐기됩니다.</p><p class="security-warning">상시 허용을 선택하면 서버 주소를 아는 모든 신규 Codmes 계정과 새 기기가 별도 수락 없이 접속할 수 있습니다.</p><label>현재 모드<select id="client-mode"><option value="ask">승인 요청 (ask)</option><option value="allow">상시 허용 (allow)</option></select></label><div class="actions"><span class="muted">현재: ${modeLabel}</span><button id="save-client-mode">모드 저장</button></div></article><div class="profile-list client-list">${rows||'<div class="empty compact">등록된 클라이언트가 없습니다.</div>'}</div>`;
  document.querySelector<HTMLSelectElement>("#client-mode")!.value=result.mode;
  document.querySelector<HTMLButtonElement>("#save-client-mode")!.onclick=async()=>{if(busy)return;const mode=document.querySelector<HTMLSelectElement>("#client-mode")!.value;if(mode==="allow"&&result.mode!=="allow"&&!window.confirm("상시 허용은 서버 주소를 아는 모든 신규 Codmes 계정을 자동 승인합니다. 계속할까요?"))return;busy=true;try{await invoke("manager_client_registration_mode",{mode});toast("클라이언트 승인 방식을 변경했습니다.");await clients()}catch(error){toast(err(error),true)}finally{busy=false}};
  document.querySelectorAll<HTMLButtonElement>("[data-client-action]").forEach(button=>button.onclick=async()=>{
    if(busy)return;
    const registrationId=button.closest<HTMLElement>("[data-registration-id]")?.dataset.registrationId;
    const action=button.dataset.clientAction;
    if(!registrationId||!action)return;
    if(action==="remove"&&!window.confirm("이 클라이언트의 등록과 세션을 삭제할까요?"))return;
    busy=true;try{await invoke("manager_client_registration_action",{registrationId,action});toast(action==="approve"?"클라이언트를 수락했습니다.":action==="reject"?"클라이언트를 거절했습니다.":"등록을 삭제했습니다.");await clients()}catch(error){toast(err(error),true)}finally{busy=false}
  });
}

async function profiles(){
  const view=document.querySelector<HTMLElement>("#view")!;
  if(!snapshot.status.managed){
    view.innerHTML='<article class="panel form"><h3>프로필 관리</h3><p class="muted">이 Manager에서 서버를 시작한 뒤 관리할 수 있습니다.</p></article>';
    return;
  }
  let result:{profiles:ManagedProfile[]};
  try{
    result=await invoke<{profiles:ManagedProfile[]}>("manager_profiles");
  }catch(error){
    if(err(error).includes("Unauthorized")){managerSignedIn=false;await invoke("manager_account_logout").catch(()=>{});await renderAuth();return}
    throw error;
  }
  const rows=result.profiles.map(profile=>`<article class="panel profile-item" data-profile-id="${h(profile.id)}"><div class="list-head"><div><h3>${h(profile.name)}</h3><p class="muted">${h(profile.ownerName)} · ${profile.deleted?'삭제됨 (복구 가능)':'Codmes 계정 프로필'}</p></div>${profile.deleted?'<button class="ghost" data-action="restore">복구</button>':'<button class="ghost" data-action="archive">프로필 삭제</button>'}</div>${profile.deleted?'':'<div class="profile-controls"><input data-field="name" aria-label="프로필 이름" value="'+h(profile.name)+'" maxlength="120"/><button class="ghost" data-action="rename">이름 변경</button></div>'}</article>`).join('');
  view.innerHTML=`<div class="profile-manager-head"><p class="muted">승인된 Codmes 계정마다 프로필 하나가 자동으로 생성됩니다. 관리자는 이름 변경, 삭제·복구를 할 수 있습니다. 앱 잠금 PIN은 각 기기에만 저장되며 여기서 관리하지 않습니다. 기존 자료는 삭제하지 않습니다.</p></div><div class="profile-list">${rows||'<div class="empty compact">프로필이 없습니다.</div>'}</div>`;
  document.querySelectorAll<HTMLButtonElement>(".profile-item button[data-action]").forEach(button=>button.onclick=async()=>{
    if(busy)return;
    const row=button.closest<HTMLElement>(".profile-item")!;
    const profileId=row.dataset.profileId!;
    const action=button.dataset.action!;
    if(action==="archive"&&button.dataset.confirmed!=="true"){
      button.dataset.confirmed="true";
      button.textContent="삭제 확인";
      toast("한 번 더 누르면 프로필이 목록에서 사라집니다. 자료는 복구할 수 있습니다.");
      return;
    }
    const value=action==="rename"?row.querySelector<HTMLInputElement>('[data-field="name"]')!.value.trim():action==="pin"?row.querySelector<HTMLInputElement>('[data-field="pin"]')!.value:undefined;
    if(action==="pin"&&!/^\d{4}$/.test(value||"")){toast("PIN은 숫자 4자리여야 합니다.",true);return}
    if(action==="rename"&&!value){toast("프로필 이름을 입력하세요.",true);return}
    busy=true;
    try{await invoke("manager_profile_action",{profileId,action,value});toast(action==="archive"?"프로필을 보관했습니다.":action==="restore"?"프로필을 복구했습니다.":"변경했습니다.");await profiles()}catch(error){toast(err(error),true)}finally{busy=false}
  });
}

async function plugins(){
  const view=document.querySelector<HTMLElement>("#view")!;
  if(!snapshot.status.managed){
    view.innerHTML='<article class="panel form"><h3>플러그인</h3><p class="muted">이 Manager에서 서버를 시작한 뒤 관리할 수 있습니다.</p></article>';
    return;
  }
  let result:{plugins:ManagedPlugin[]};
  try{result=await invoke<{plugins:ManagedPlugin[]}>("manager_plugins")}
  catch(error){if(err(error).includes("Unauthorized")){managerSignedIn=false;await invoke("manager_account_logout").catch(()=>{});await renderAuth();return}throw error}
  const rows=result.plugins.map(plugin=>`<article class="panel profile-item" data-plugin-id="${h(plugin.id)}"><div class="list-head"><div><h3>${h(plugin.name)}</h3><p class="muted">${plugin.installed?`서버 설치 버전 ${h(plugin.installedVersion)}`:'설치되지 않음'} · Marketplace 최신 ${h(plugin.version)}</p></div><button data-plugin-action="${plugin.installed?'update':'install'}" ${plugin.blocked||plugin.installed&&!plugin.updateAvailable?'disabled':''}>${plugin.installed?'업데이트':'설치'}</button></div>${plugin.permissionChangeRequired?`<p class="muted">추가 권한: ${h(plugin.addedPermissions.join(', '))}</p>`:''}</article>`).join('');
  view.innerHTML=`<div class="profile-manager-head"><p class="muted">패키지는 서버에 한 번 설치합니다. 여기서 업데이트하면 모든 프로필에 적용되고, 로그인 정보·사용 여부·데이터는 프로필별로 유지됩니다.</p></div><div class="profile-list">${rows||'<div class="empty compact">Marketplace 플러그인이 없습니다.</div>'}</div>`;
  document.querySelectorAll<HTMLButtonElement>("[data-plugin-action]").forEach(button=>button.onclick=async()=>{
    if(busy)return;
    const plugin=result.plugins.find(item=>item.id===button.closest<HTMLElement>("[data-plugin-id]")?.dataset.pluginId);
    if(!plugin)return;
    if(plugin.permissionChangeRequired&&!window.confirm(`${plugin.name} 업데이트가 새 권한을 요청합니다:\n${plugin.addedPermissions.join('\n')}\n\n모든 프로필에 적용할까요?`))return;
    busy=true;
    try{
      await invoke("manager_plugin_action",{pluginId:plugin.id,action:button.dataset.pluginAction,version:plugin.version,acceptedPermissions:plugin.addedPermissions});
      toast(`${plugin.name} ${button.dataset.pluginAction==='install'?'설치':'업데이트'} 완료. 모든 프로필에 적용됩니다.`);
      await plugins();
    }catch(error){toast(err(error),true)}finally{busy=false}
  });
}
