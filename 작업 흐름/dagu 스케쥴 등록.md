# App 자체적으로 관리

- App 상에서 `dags/*.yml` 파일들을 작성
- 스케쥴 등록 스크립트를 실행하면 `working_dir`을 자동으로 입력해서 `~/.config/dagu/dags/`에 복제
  - `git pull`시에 dags 변경이 있으면 업데이트 해야할텐데... 이걸 어떻게 처리할지는 좀 더 고민이 필요