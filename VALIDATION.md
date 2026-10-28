# CoolSync 0.3.0 검증 기록

검증일: 2026-10-26

## 통과한 검사

- Android assembleDebug 성공, lintDebug 오류 0개·경고 9개. Android 12 이상, compile/target SDK 36. 경고는 ScopedStorage, ApplySharedPref, OldTargetApi, ObsoleteSdkInt, UsableSpace, MonochromeLauncherIcon, DrawAllocation 2건, SetTextI18n이다.
- 0.2.0의 시작 오류를 별도 Android 에뮬레이터에서 재현했다. DecorView 생성 전 insetsController 접근이 원인이었고, setContentView 이후로 옮겼다.
- 최종 0.3.0 APK의 콜드 시작·프로세스 유지·크래시 로그 검사를 통과했다. Android 권한 통합 창과 메인 화면을 에뮬레이터에서 확인했다.
- 실제 Android ART에서 저장소 코어 검사 통과: 생성·목록·이름 변경·재귀 복사/이동·휴지통·복원·영구 삭제. 경로 이탈·이름 충돌 거부 및 외부 확인 파일 보존. 같은 코어의 JVM 검사도 통과했다.
- 휴지통의 원래 경로 정보가 내부 인덱스 유실 후에도 재구성되는 것을 확인했다.
- Mac 탐색기 RPC 검사 통과: 요청 응답 대응, 목록 페이지 처리, 선택·잘라내기·붙여넣기, 검색, 휴지통·복원 및 연결 종료 시 작업 정리.
- Mac Swift 컴파일·앱 패키징 성공. Apple Silicon arm64, macOS 13 이상.
- 클립보드 JCE ↔ CryptoKit 암호화 상호 운용, 잘못된 키·변조·만료 메시지 거부 및 최대 이스케이프 텍스트 검사 통과.
- 실제 Mac 송수신 코드와 JCE 테스트 클라이언트 사이 TCP 양방향 파일 전송 통과: 방향별 196,665바이트, AES-GCM·SHA-256·저장 완료 응답. 잘못된 해시 거부, 기존 파일 보존, 임시 파일 정리 확인.
- QR 비트맵을 별도 ZXing 디코더로 읽어 URI·연결 키 보존 확인.
- 네이티브 Mac 화면 4종 렌더링·시각 확인. 미리보기 기기 및 파일은 샘플 데이터다.
- Android 클립보드는 이벤트 기반이며 주기적인 클립보드 조회 타이머·WakeLock·READ_LOGS·위치·Bluetooth 검색 권한이 없는 것을 코드로 확인했다.

## 검증의 한계

0.1.0의 실제 클립보드 공유는 사용자가 확인했다. 이번 버전을 사용자 휴대폰에 설치하거나 실행 중인 Mac 앱으로 교체하지 않았다. 테스트는 별도 일회성 에뮬레이터와 합성 파일을 사용했다.

실제 갤럭시와 Mac 사이의 QR 연결, BLE 탐색기 요청, Finder 드래그, 폴더 전송, 절전·재부팅 복구, 장시간 배터리 소모는 아직 검증하지 않았다. 로컬 TCP 검사는 실제 무선 연결이나 전체 Android 전송 경로를 검증한 것은 아니다.

파일 내용 전송은 같은 Wi-Fi에서 파일당 256MiB까지 지원한다. 휴대폰 내부 파일의 복사/이동에는 이 크기 제한이 없다. 공유 내부 저장소만 대상으로 하며 보호된 앱 데이터·시스템 폴더는 접근하지 않는다. 폴더 작업 도중 오류가 나면 완료된 일부 작업은 남을 수 있다.

Mac 앱은 개인용 ad-hoc 서명이며 Apple 공증은 받지 않았다. Android APK는 기존 CoolSync와 같은 개발 인증서로 서명했다.

## 입력창 및 탐색 구조 수정

버전은 유지했다. 새 작업 경로에서 Android assembleDebug/lintDebug 및 Mac 빌드를 통과했다. Android 에뮬레이터에서 네 탭 전환, 입력창 열기·취소, 잘못된 키의 인라인 오류와 창 유지, 가로 화면, 연결 진단 창, 프로세스 생존 검사를 통과했다. 실제 스크린샷은 design/previews/android-connection.png, android-pairing.png, android-input-error.png, android-pairing-landscape.png, android-diagnostics.png이다. Mac 탐색기 RPC 회귀 검사도 통과했다. 실제 기기 무선 연결의 실패 원인은 미확정이다.

## GitHub automatic updates (2026-10-26)

- Public repository: https://github.com/hun8902/CoolSync
- GitHub Actions run 40258293361: Android release build/lint, macOS build/explorer RPC, signed metadata and release publishing all succeeded.
- Published release: build-1002. Display version remains 0.3.0; internal build is 1002.
- Downloaded the actual release assets and verified Android APK/metadata signatures, Mac package signature, embedded public key/build and Sparkle Ed25519 archive signature. Tampered signature inputs were rejected.
- A disposable Android emulator running build 4 fetched the real GitHub feed, downloaded the APK, verified it and opened the system installer. Play Protect scan passed; installation advanced to build 1002 and cold launch survived.
- The user's physical phone and installed Mac app were not replaced. A full Mac in-place Sparkle replacement has not been tested.


## Clipboard history, image clipboard and UI revision

- Local history bounds, deduplication, favorites, persistence, disabled recording and image deletion passed on the actual Mac history implementation.
- Disposable Android emulator: history limit/favorites/dedup passed; copying a synthetic PNG produced an image/png clipboard URI readable through the real content provider. Deleting its history entry did not invalidate the current clipboard image.
- Actual Mac image-offer receiver and a JCE client: encrypted PNG transfer, automatic image acceptance, hash/image validation and image callback passed.
- Existing encrypted binary transfer and explorer RPC regression checks passed.
- Android settings/history were captured and inspected in portrait and landscape. Mac clipboard/settings previews use isolated synthetic data. A short actual Android tab-animation recording is available locally.
- Android clipboard capture remains event driven; no clipboard polling, WakeLock or ADB requirement was introduced.
- The translucent surfaces are platform-adapted visuals. Android does not use Apple's native Liquid Glass framework; compositor blur falls back to translucency when unavailable.
- Physical Galaxy-to-Mac image synchronization and paste into KakaoTalk or other third-party apps have not been verified. Source URI access and destination app image-paste support are required. Image clipboard payloads require the local-network transfer path.

## Photo gallery implementation

Added album/media RPCs, on-demand encrypted Wi-Fi thumbnails, a macOS Photos-style grid and inspector, local original-file preview/video playback, multi-selection and bidirectional drag/export. User requested build and deployment only; no new runtime, device, screenshot or scenario tests were performed for this gallery revision. Android and macOS compiler results and GitHub release state are reported separately.

## 2026-10-28 메시지 수신함 / Dock

- 기존 원본 저장소에서 Mac 빌드·코드 서명 검증, Android assembleDebug 통과.
- `tests/message-inbox-tests.swift`: 인증번호 추출, 민감 내용·제목·검색 가림, SMS 중복 제거, 500개 제한, 파일 저장/재읽기, 연결별 분리, 페이지 동기화 통과.
- 실제 SwiftUI 렌더링으로 메시지 라이트/다크·선택 목록·말풍선·인증번호 버튼·숨김 화면 확인. 실제 사용자 메시지는 사용하지 않음.
- 읽기 전용 Pixel_10_Pro 에뮬레이터에서 설치·실행, 문서의 appops 추가 허용 명령, 가상 SMS 인증번호 수신과 앱 알림 수신, Android 알림함 진입 및 복사 버튼 표시 확인. AndroidRuntime 크래시 없음.
- 별도 macOS 테스트 프로세스에서 regular/accessory 활성화 정책 전환 통과. 실행 중인 사용자 앱의 정책은 변경하지 않음.
- 실제 Fold의 SMS/OTP 권한·수신, 실제 두 기기 BLE 알림함 동기화와 Mac 시스템 알림 액션은 아직 확인하지 않음. MMS/RCS 과거 대화 가져오기와 문자 전송은 포함하지 않음.
