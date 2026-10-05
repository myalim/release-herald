---
name: show
description: 지난 Claude Code 릴리스의 한국어 요약을 버전·범위·낱말·영역으로 조회한다 — 세션 시작 화면에서 잘렸거나 이미 지나간 변경을 찾아볼 때. 인자 없이 부르면 릴리스 목록이다.
argument-hint: "[버전 | 시작..끝] [--find 낱말] [--area 영역] [--all] [--en]"
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/hooks/show.sh), Bash(${CLAUDE_PLUGIN_ROOT}/hooks/show.sh *)
---

아래 명령을 그대로 실행하고, 출력을 요약하거나 다시 쓰지 말고 그대로 보여준다.

```bash
${CLAUDE_PLUGIN_ROOT}/hooks/show.sh $ARGUMENTS
```

인자 형태는 `${CLAUDE_PLUGIN_ROOT}/hooks/show.sh --help` 가 갖는다. 출력이 오류면 그 문구를 그대로 전한다.
