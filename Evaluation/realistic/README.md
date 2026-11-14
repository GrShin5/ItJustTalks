# Realistic cleanup development set

120 synthetic dictation cases for developing cleanup evaluation. People, organizations, products, and situations are fictional; no real personal data is used. Cases share recurring scenarios and are not independent samples of real user speech.

| Coverage | Cases |
|---|---:|
| Japanese / English | 110 / 10 |
| Japanese transcript length: 80–149 / 150–249 / 250–400 characters | 36 / 44 / 30 |
| Multiple sentences | 120 |
| STT punctuation / no STT punctuation | 65 / 55 |
| Open ending | 22 |
| Three or more dictionary entries | 30 |
| Cued / cueless correction | 25 / 15 |
| Filler / repetition | 32 / 22 |
| Numbers / hands-free | 40 / 10 |

Each JSONL object has `id`, `category`, `lang`, `purpose`, `critical`, `input`, and `expect`. Input contains `transcript`, `customInstruction`, `dictionary` entries (`preferred`, `readings`, `memo`), `outputLanguage`, and `handsFree`. Expectations contain `mustContain`, `mustNotContain`, `language`, `noAnswer`, `correction`, `reference`, `endsOpen`, `dictionarySurfaces`, optional `corrections`, and `tags`. `reference` preserves the spoken content and unfinished endings while removing fillers and retracted content; dictionary surfaces use preferred spellings. Tags overlap.
