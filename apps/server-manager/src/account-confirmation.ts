let pendingConfirmation: Promise<boolean> | null = null;

export function confirmGoogleAccountChange(documentRoot: Document = document, unlink = false): Promise<boolean> {
  if (pendingConfirmation) return pendingConfirmation;
  const previousFocus = documentRoot.activeElement;
  const dialog = documentRoot.createElement("dialog");
  dialog.className = "account-confirmation";
  dialog.setAttribute("aria-labelledby", "account-change-title");
  dialog.setAttribute("aria-describedby", "account-change-description");
  dialog.innerHTML = `<h2 id="account-change-title">Google 연결 ${unlink ? "해제" : "변경"}</h2><p id="account-change-description">Codmes 계정과 ID·비밀번호, 프로필, 자료, 기기 승인은 유지됩니다. 다른 로그인 세션만 종료됩니다.${unlink ? " 이후 ID·비밀번호로 로그인하세요." : " 새 Google 계정으로 인증하면 연결된 로그인 수단이 바뀝니다."}</p><p class="muted">취소하거나 인증을 완료하지 않으면 연결은 변경되지 않습니다.</p><div class="actions"><button type="button" class="ghost" data-cancel>취소</button><button type="button" data-confirm>${unlink ? "연결 해제" : "Google 계정 선택"}</button></div>`;
  const promise = new Promise<boolean>((resolve, reject) => {
    dialog.addEventListener("close", () => {
      const confirmed = dialog.returnValue === "confirm";
      dialog.remove();
      if (previousFocus instanceof HTMLElement && previousFocus.isConnected) previousFocus.focus();
      resolve(confirmed);
    }, { once: true });
    dialog.querySelector<HTMLButtonElement>("[data-cancel]")!.onclick = () => dialog.close("cancel");
    dialog.querySelector<HTMLButtonElement>("[data-confirm]")!.onclick = () => dialog.close("confirm");
    try {
      documentRoot.body.append(dialog);
      dialog.showModal();
      dialog.querySelector<HTMLButtonElement>("[data-cancel]")!.focus();
    } catch (error) {
      dialog.remove();
      reject(error);
    }
  });
  pendingConfirmation = promise.finally(() => { pendingConfirmation = null; });
  return pendingConfirmation;
}
