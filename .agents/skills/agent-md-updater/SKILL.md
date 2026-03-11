---
name: agents-md-updater
description: "Modify AGENTS.md. Use when adding, removing, or changing project rules, paths, or descriptions."
---

PURPOSE
Update AGENTS.md by adding, updating, or removing entries using ONLY the exact plain text and tag syntax found in AGENTS.md. No markdown, no extra formatting, no chapter headers.
AGENTS.md loads every turn. The agent trusts what's always there, so stale paths and old rules mislead it. Keep the file small so the agent focuses on current work. Push details into skills that only load when relevant.

The exact structure of AGENTS.md is:

[plain text project description — no tag wrapping]

<Global_rules>
- rule
</Global_rules>

<kubernetes>
[plain text kubernetes description]
<kubernetes_rules>
- rule
</kubernetes_rules>
</kubernetes>

<opentofu>
[plain text opentofu description]
<opentofu_rules>
- rule
</opentofu_rules>
</opentofu>

<mail>
[plain text mail description]
<mail_rules>
- rule
</mail_rules>
</mail>

RULE QUALITY STANDARD
- Every rule must state one direct action.
- Every rule must name the target object or area.
- Every rule must use concrete words.
- Every rule must avoid vague terms such as proper, clear, robust, clean, or as needed.
- Every rule must stand alone without extra interpretation.
- Every rule must map to one behavior that can be checked.
- Never use the word if.

FILE STRUCTURE RULES
- Edit only lines requested by the user.
- Preserve all existing tag names exactly.
- Preserve tag order exactly as present in AGENTS.md.
- Preserve opening and closing tag pairs exactly as present in AGENTS.md.
- Preserve plain text style and bullet style already used in AGENTS.md.
- Top project description is plain text with no wrapping tag.
- Add no markdown headings.
- Add no code fences.
- Add no wrapper tags.
- Add no new section shape.

WORKFLOW
1. Identify the change (add, update, remove)
2. Edit AGENTS.md using ONLY the structure shown above
3. Do NOT add markdown, chapter headers, or any formatting not present in AGENTS.md
4. If more detail is needed, reference a skill by name only. Never inline details
5. Review to ensure the file remains strictly in the accepted format

COMPLETION CHECK
- All entries use only the allowed plain text and tag syntax
- No markdown, chapter headers, or extra formatting present
- The always-on context remains minimal and focused
