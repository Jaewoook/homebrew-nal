## Description

<!-- Provide a brief description of the formula update, addition, or tap workflow fix. -->

## Related Issue

<!-- Link the issue(s) this PR resolves or relates to: -->
- Closes #
- Related to #

## Type of Change

- [ ] 🆕 New Formula or Cask addition
- [ ] ⬆️ Formula or Cask version update / revision bump
- [ ] 🍾 Bottle checksum / manifest update
- [ ] 🐛 Bug fix in Formula/Cask specification or tap script
- [ ] ⚙️ CI / GitHub Actions workflow update
- [ ] 📝 Documentation update

## Verification Checklist

- [ ] `brew audit --strict --online <formula>` (or `brew style`) passes without fatal errors.
- [ ] Formula installs cleanly from source or bottle: `brew install --build-from-source <formula>` (or Cask verifies `x86_64` slice).
- [ ] `brew test <formula>` passes (for formula changes).
- [ ] Script test suite passes (`for t in tests/test_*.sh; do bash "$t"; done`).
