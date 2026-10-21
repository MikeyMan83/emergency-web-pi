---
name: frontend-first
description: Enforce frontend-first iteration and delay Windows packaging until final implementation is complete.
user-invocable: true
---

# Workflow Rules & Constraints

You must strictly adhere to the following development workflow:

1. **Visual Iteration:** Use the development frontend for all visual and UI iterations. Do NOT repeatedly package or build the Windows application during development.
2. **Implementation First:** Complete the entire design and implementation phase first within the frontend environment.
3. **Batch Checks:** Run all available checks, tests, and linters together only after the implementation is complete.
4. **Final Packaging:** Package the final candidate exactly ONCE after all checks have passed.
//5. **No Publishing:** Do NOT publish a release.