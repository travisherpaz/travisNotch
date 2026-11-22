# travisNotch

Boring Notch의 개인 fork이고, 지인들에게 Sparkle 자동 업데이트로 배포한다(`Configuration/release.sh`).

## 업데이트로 사용자 데이터를 잃으면 안 된다

설정과 메모(`notesRTF`), 할 일(`todos`)은 번들 ID별 샌드박스 컨테이너의 UserDefaults에
저장되며, 업데이트 뒤에도 그대로 남아 있어야 한다.

- 번들 ID(`com.travisherpaz.travisnotch`, `…BoringNotchXPCHelper`)는 절대 바꾸지 않는다. 바꾸면
  새 앱이 빈 컨테이너에서 시작해서 모든 설정과 메모가 사라진 것처럼 보인다.
- 저장된 값의 `Defaults.Key` 이름이나 타입을 바꿀 때는, 첫 실행 시 옛 키를 읽어 새 키로
  옮기는 마이그레이션을 같은 커밋에 넣는다. 예전에 `notes`를 `notesRTF`로 바꾸면서 이걸 빠뜨려
  기존 메모가 옛 키에 남은 채 버려진 적이 있다.
- 옛 키는 마이그레이션 뒤에도 지우지 않는다(되돌릴 여지).
