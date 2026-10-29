## Description

<!-- Provide a brief description of the formula update, addition, or tap workflow fix. -->

## Related Issue

<!-- Link the issue(s) this PR resolves or relates to: -->
- Closes #
- Related to #

## Type of Change

- [ ] 🆕 New Formula addition
- [ ] ⬆️ Formula version update / revision bump
- [ ] 🍾 Bottle checksum / manifest update
- [ ] 🐛 Bug fix in Formula Ruby specification
- [ ] ⚙️ CI / GitHub Actions workflow update
- [ ] 📝 Documentation update

## Formula Verification Checklist

- [ ] `brew audit --strict --online <formula>` passes without fatal errors.
- [ ] Formula installs cleanly from source or bottle: `brew install --build-from-source <formula>`.
- [ ] `brew test <formula>` passes.
- [ ] Commits are GPG signed (`git commit -S`).
