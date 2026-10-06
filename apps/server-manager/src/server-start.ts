export type ServerSetup = {
  existingServer: boolean;
  maskedAccount: { id: string; email: string } | null;
  resetAllowed: boolean;
  resetUnavailableReason: string | null;
};

export const RESET_CONFIRMATION = "기존 서버 삭제";
const escapeHtml = (value: string) => value.replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

export function existingServerChoice(setup: ServerSetup): string {
  const hint = setup.maskedAccount?.email || setup.maskedAccount?.id || "기존 관리자 계정";
  return `<div class="server-choices">
    <button id="continue-server" class="server-choice"><strong>기존 서버로 계속하기</strong><span>${escapeHtml(hint)}</span><small>Codmes ID·비밀번호 또는 연결된 Google 계정으로 로그인합니다.</small></button>
    <button id="fresh-server" class="server-choice danger-choice" ${setup.resetAllowed ? "" : "disabled"}><strong>새 서버로 시작하기</strong><small>기존 서버의 모든 계정·승인·자료를 삭제하고 새 관리자 계정을 만듭니다.</small></button>
  </div>${!setup.resetAllowed ? `<p class="security-warning">${escapeHtml(setup.resetUnavailableReason || "이 저장소는 안전하게 초기화할 수 없습니다.")}</p>` : ""}`;
}

export function resetWarning(): string {
  return `<div class="reset-warning" role="note"><strong>기존 서버 전체가 초기화됩니다.</strong>
    <ul><li>관리자와 클라이언트 계정·프로필·기기 승인</li><li>서버에 저장된 파일·PDF 필기·대화·플러그인 데이터와 설정</li></ul>
    <p>완료 후 복구할 수 없습니다. 아직 클라이언트 서버 이동용 내보내기 기능은 없습니다. 서버에만 있는 자료는 직접 백업한 후 진행하세요.</p>
    <p>다른 기기의 로컬 파일과 해당 Google 계정 자체는 삭제하지 않습니다. Google/컴퓨터 관리자 확인을 취소하거나 새 계정 생성에 실패하면 기존 서버를 유지합니다.</p></div>`;
}

export function resetConfirmationFields(): string {
  return `<label>삭제 확인 문구<input id="reset-confirmation" autocomplete="off" placeholder="${RESET_CONFIRMATION}" required/></label>
    <label class="reset-acknowledgement"><input id="reset-ack" type="checkbox" required/>기존 서버의 모든 계정과 자료가 삭제됨을 이해했습니다.</label>`;
}

export function resetConfirmed(text: string, acknowledged: boolean): boolean {
  return text === RESET_CONFIRMATION && acknowledged;
}
