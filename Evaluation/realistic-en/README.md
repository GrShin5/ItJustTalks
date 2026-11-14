# Realistic English cleanup development set

120 synthetic English dictation cases for developing cleanup evaluation. People, organizations, products, and situations are fictional; the email example uses the reserved example domain. These cases are constructed examples, not independent samples of real user speech.

| Coverage | Cases |
|---|---:|
| English | 120 |
| Transcript length 80–400 characters | 100 |
| Multiple sentences | 114 |
| STT punctuation / no STT punctuation | 58 / 62 |
| Cued correction | 20 |
| Explicit contrast to preserve | 8 |
| Open ending | 15 |
| Pause filler | 25 |
| Dictionary entries / three or more entries | 30 / 15 |
| Numbers or quantities | 24 |
| Tone and wording focus | 15 |
| Hands-free | 8 |
| Short phrases (at most eight characters) | 6 |
| Long run-on passages | 6 |
| Email example | 1 |

Coverage overlaps: for example, some corrections contain quantities, and some open endings contain fillers. Numbers include digits and spoken number words. Tone-preservation traps also occur outside the 15 dedicated cases. The hands-free flag describes the cleanup input after the send trigger has been removed; these cases do not test actual sending.

Each JSONL object has `id`, `category`, `lang`, `purpose`, `critical`, `input`, and `expect`. Input contains `transcript`, `customInstruction`, `dictionary` entries (`preferred`, `readings`, `memo`), `outputLanguage`, and `handsFree`. Expectations contain `mustContain`, `mustNotContain`, `language`, `noAnswer`, `correction`, `reference`, `endsOpen`, `dictionarySurfaces`, optional `corrections`, and `tags`. The reference preserves spoken words and unfinished endings, removes pause fillers and cued retractions, and uses dictionary spellings. It does not contract or reword speech. Tags overlap.
