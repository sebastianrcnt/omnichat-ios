# Pretendard 1.3.9

Release: https://github.com/orioncactus/pretendard/releases/tag/v1.3.9 (asset `Pretendard-1.3.9.zip`,
SHA-256 `04be351a74d6bf7d60c480a3087e51d185485d35a52023142af1df19eb8c428a`). License: SIL OFL 1.1
(`Pretendard-OFL.txt`, from the release's `LICENSE.txt`).

Each file below was checked two ways: its SHA-256 is recorded here, and its git blob SHA-1 equals the blob at tag
`v1.3.9` in the repository (`packages/pretendard/dist/public/...`, `LICENSE.txt`).

| File | SHA-256 | git blob (tag v1.3.9) |
| --- | --- | --- |
| PretendardVariable.ttf | 3090ccde0442bb347aa7685d9ba8b17436a60682df6e8f92a9a670de14056e22 | 32b0811eae2cbfeb5f6ddaf34015ecaa726b006a |
| Pretendard-Regular.otf | 3ffbacde6ab8411f1d2db54bb9b1f0b3ee2a738932033722cf0388c06aed1c93 | 08bf4cfc2164a0bff74a4bf844128d3b843bbf87 |
| Pretendard-Medium.otf | d39e50e4bb52b4993b6a4eeb821a171254745bd824446af01e1f616b89fface0 | 057506983f0a8b0438fc5f24382db64497bf6eae |
| Pretendard-SemiBold.otf | c89bc43027dc7cde5726e96223376f8eec09302b2fc1f8147fd5b57cfc376118 | e7e36abc474796c8b6c383380ddd9f87655682ec |
| Pretendard-Bold.otf | 2e91915fab54df71cc9598ebf608b2bdb54c6fe3c066ac61dff0bc44fca71cc7 | 8e5e30a28b4435359945cf08b261c86d0de8da53 |
| Pretendard-OFL.txt (LICENSE.txt) | b04538c9abec39a3db75108cf0af0fd9c77032fe8aa2cf38345b4d250e98e38e | 497b88f9fa7623ba9f8fdac86b43dec5621984ed |

The app uses the variable font (`Font.custom("Pretendard Variable", ...).weight(...)` selects the weight; checked to render
Regular, Medium, SemiBold and Bold distinctly on iOS 26). The four static OTFs are registered too, as a fallback.
