# Repo-scoped stack skills

Stack knowledge (a framework, a language's build tool, a deploy stack) belongs in the repo, not in the global skill set. A repo that does not use the stack should never see its skills.

- **Location:** `.claude/skills/<name>/SKILL.md` for Claude Code. Mirror the same content in `.agents/skills/<name>/SKILL.md` for Codex, OpenCode and other agents.
- **Collisions first:** Claude Code gives a personal skill precedence over a project skill with the same name, so a repo skill named like a global skill is silently shadowed. Check the global catalog and rename the repo skill.
- **Content:** only what an agent cannot infer from the code: exact commands, traps and conventions. No tutorials.
- **Size:** keep each skill short, and cover one stack per skill.
- **Pin:** name the versions the skill depends on.
- **Scripts and hooks:** do not ship executable files in a stack pack. Read every file of a third-party pack before installing it.
- **Review:** commit repo skills like code. Changes need the same review as `AGENTS.md`.
