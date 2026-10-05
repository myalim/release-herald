# Changelog

## [0.1.1](https://github.com/myalim/release-herald/compare/v0.1.0...v0.1.1) (2026-10-05)


### Bug Fixes

* 조회와 세션 시작 화면의 내부 용어를 사용자 문구로 정돈 ([#16](https://github.com/myalim/release-herald/issues/16)) ([ca2f13d](https://github.com/myalim/release-herald/commit/ca2f13d6ebd90478c29eeb9654befea2eb0331d6))

## 0.1.0 (2026-10-05)


### Features

* **hooks:** 주요 변경이 없는 릴리스도 참고 한 줄이나 안내로 표시 ([#9](https://github.com/myalim/release-herald/issues/9)) ([f0d0599](https://github.com/myalim/release-herald/commit/f0d05997cdad32e4eee76125dc0c202b92bb98df))
* 릴리스 요약 데이터 계약과 생성기 골격 ([#1](https://github.com/myalim/release-herald/issues/1)) ([c79df29](https://github.com/myalim/release-herald/commit/c79df29b377c9d0858ebd929afda23b9a4bddf93))
* 릴리스 요약 파이프라인을 세션 시작 화면까지 연결 ([#3](https://github.com/myalim/release-herald/issues/3)) ([df44975](https://github.com/myalim/release-herald/commit/df4497503518c032c41c817086b5e2002a44fa75))
* 릴리스 항목 영역 판정과 낱말·영역 조회 추가 ([#10](https://github.com/myalim/release-herald/issues/10)) ([741f295](https://github.com/myalim/release-herald/commit/741f295d500e2bb5807b93064d7cf5c82684f05c))
* 요약 생성 자동화 파이프라인 ([#2](https://github.com/myalim/release-herald/issues/2)) ([adacd45](https://github.com/myalim/release-herald/commit/adacd4590134924b2bb173ff96cf2e28d22de3a0))
* 지난 릴리스를 골라 보는 조회 도구 ([#6](https://github.com/myalim/release-herald/issues/6)) ([3188def](https://github.com/myalim/release-herald/commit/3188def8c78504671966bffbbc10e86a5a84abd9))
* 플러그인 공개 준비와 요약 생성 멈춤 알림 ([#13](https://github.com/myalim/release-herald/issues/13)) ([a5c43a1](https://github.com/myalim/release-herald/commit/a5c43a1e017cf975192a2a2c206c7324ec1baa0d))


### Bug Fixes

* **hooks:** 실행 중인 버전까지만 릴리스를 통지 ([#11](https://github.com/myalim/release-herald/issues/11)) ([524cc71](https://github.com/myalim/release-herald/commit/524cc718b8126671a10773bae73bcc8c9f959210))
* 되돌림 항목이 화면에서 잘리던 판정 기준 교정 ([#5](https://github.com/myalim/release-herald/issues/5)) ([f76363f](https://github.com/myalim/release-herald/commit/f76363f71d739ba05830298bf61e6ac2cc76a2a7))
* 릴리스 감지 지연과 침묵 진단 오진 교정 ([#4](https://github.com/myalim/release-herald/issues/4)) ([167e252](https://github.com/myalim/release-herald/commit/167e2520f98eced2755438de80763328b2dbba05))
* 통지 지연 교정과 판정 루프 분리 ([#7](https://github.com/myalim/release-herald/issues/7)) ([248340d](https://github.com/myalim/release-herald/commit/248340d8a5ca9e381440fa71fd636cedb9d9b269))


### Performance

* **hooks:** 바뀌지 않은 원본은 조건부 요청으로 건너뜀 ([#8](https://github.com/myalim/release-herald/issues/8)) ([8c1ba08](https://github.com/myalim/release-herald/commit/8c1ba08a13e2c6051cf7d5b7a7f8f2779e48ef71))
