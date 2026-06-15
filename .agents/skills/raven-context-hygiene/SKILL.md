---
name: raven-context-hygiene
description: Use at unit completion and when the user signals a new unrelated task is beginning.
---

# Context Hygiene

## Skip When

- The session just started and there is no prior work in context.
- The new request is a direct follow-up to what was just discussed.

## Process

1. Identify the trigger:
   - Unit completion: invoked after `raven-session.py --complete`
   - New-session language: user says something like "now let's work on X" or "next up is Y"
2. Ask: "Looks like we're starting something new — would you like to `/clear` context, `/compact`, or continue as-is?"
3. Wait for response, then proceed accordingly.
