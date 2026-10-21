# Contributing

mxlt-utils is a growing collection of native Mac utilities, shaped by everyday needs. Ideas for useful additions, bug reports, small fixes, and clearer documentation are all welcome.

## Report a bug or suggest an improvement

[Open an issue](https://github.com/Mxlted/mxlt-utils/issues/new/choose). For bugs, include the mxlt-utils version, macOS version, affected app and version, steps to reproduce, and what you expected to happen. For scrolling problems, include your mouse model and any other mouse utilities you use.

Remove private information from screenshots and logs. Please don't include document contents or keystrokes. Check the [known compatibility limits](docs/TESTING.md#compatibility-evidence) and existing issues first.

For a larger feature or change to input handling, describe the proposal in an issue before starting implementation so its scope can be discussed.

## Make a change

1. Fork the repository and create a branch for one focused change.
2. Follow the [development guide](docs/DEVELOPMENT.md) to build locally. Open `Package.swift` in Xcode; no separate project generator is needed.
3. Keep behavior changes covered by relevant tests. Run `swift test`, `./scripts/build.sh`, and `git diff --check` for source changes. For documentation-only changes, check wording, links, and whitespace.
4. Open a pull request explaining the problem, what changed, and how you checked it. Include screenshots for visible UI changes.

Use disposable fixtures for close and scroll tests. State whether evidence comes from unit tests, synthetic events, or physical input; they verify different things. The [testing guide](docs/TESTING.md) explains the existing checks.

## Design boundaries

- Keep CallQuits and middle scrolling independently enabled, with settings retained when disabled.
- Quit only after a verified close action. Preserve save prompts, exclusions, window checks, and protected apps; uncertain state must keep the app running.
- Preserve normal wheel and trackpad input. Cancel held scrolling safely, and never turn synthetic input into a new close action.
- Use public macOS APIs, keep work out of input callbacks, and avoid adding runtime dependencies for small features.
- Keep user-facing copy clear and brief. Don't collect personal content or input history for diagnostics.

Keep generated output, signing material, and credentials out of commits. Contributions are covered by the project's [MIT license](LICENSE); retain applicable notices when adapting existing code.
