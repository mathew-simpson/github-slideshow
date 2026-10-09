# CLAUDE.md

Jekyll + reveal.js slideshow. Slides are markdown in `_posts/`, layouts in `_layouts/`, includes in `_includes/`.

## Token budget rules
- Do not read or grep `node_modules/` or `_site/`. Both are denied in `.claude/settings.json`. `node_modules/reveal.js` is vendored and is never the place to edit.
- Use Glob/Grep with `glob` filters on `_posts`, `_layouts`, `_includes`, `script`. Avoid whole-repo sweeps.
- Read files with offset/limit when they are large. Don't re-read files already in context.
- Keep replies short. Report results and diffs, not narration.

## Commands
- `script/setup`: install gems and submodules.
- `script/server`: `bundle exec jekyll serve` for local preview.
- `script/cibuild`: build `_site` and run htmlproofer. Run before pushing content changes.

## Conventions (from .editorconfig)
- Default indent is tabs, 4 wide. JSON, JS, CSS, YAML and HTML use 2 spaces.
- Markdown uses 4-space indent, keeps trailing whitespace, and ends with a final newline.
- LF line endings, UTF-8.

## Git
- Develop on the branch named in the session instructions. Do not push to other branches.
