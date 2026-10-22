# Licensing

Copyright (C) 2026 the OmniChat developer.

## The app

OmniChat (the iOS and macOS app: `Strata/`, `StrataMac/`, `StrataShare/`, `Widgets/`, `StrataTests/`, `Tools/`) is free
software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the
Free Software Foundation, version 3 of the License, or (at your option) any later version. See [LICENSE](LICENSE).

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied
warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

## The package SDK

The package format, its SDK and the example packages (`Packages/`) are under the MIT License
([Packages/OmniChatPackageKit/LICENSE](Packages/OmniChatPackageKit/LICENSE)).

### Additional permission for packages

As an additional permission under section 7 of the GNU GPL version 3, a package that OmniChat loads through its package
interface (the package format and APIs described in [docs/PACKAGES.md](docs/PACKAGES.md)) is not considered a work based
on OmniChat because it is loaded and run by it. You may write, use and distribute such packages under terms of your
choice. This permission does not cover changes to OmniChat itself.

## Third-party components

Bundled components keep their own licenses. The files are next to them, and the app lists them under
Settings → Licenses:

- libssh2 (BSD-3-Clause), OpenSSL (Apache-2.0): `Strata/Resources/Licenses/`
- Pyodide, including CPython (MPL-2.0, PSF License): `Strata/Resources/PyRuntime/pyodide/LICENSE`
- highlight.js (BSD-3-Clause): `Strata/Resources/Highlight/LICENSE.md`
- Readability (Apache-2.0): `Strata/Resources/Readability/LICENSE.md`
- Pretendard (SIL Open Font License 1.1): `Strata/Resources/Fonts/Pretendard-OFL.txt`
- swift-markdown-ui, NetworkImage (MIT) and swift-cmark (BSD-2-Clause), through Swift Package Manager

## Name

"OmniChat" and its logo are the developer's trademarks. The GPL covers the code, not the name: a modified version you
distribute must use a different name and icon.

## Contributions

Contributions are accepted under the [Contributor License Agreement](CLA.md), so the app can keep being distributed on the
App Store and offered under other licenses.
