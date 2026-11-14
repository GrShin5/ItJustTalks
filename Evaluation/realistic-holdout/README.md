# SEALED realistic cleanup holdout

This synthetic-only set evaluates daily dictation cleanup on 60 fictional cases. Run it **once per candidate**; never tune on this set or use its cases to develop prompts or rules. Keep candidate development and evaluation separate from this sealed holdout.

Counts overlap because each case may have several tags. Lengths are transcript character counts for the 55 Japanese cases; five additional cases are English.

| Distribution | Count |
| --- | ---: |
| Japanese: 80–149 / 150–249 / 250–400 characters | 13 / 24 / 18 |
| multiSentence / sttPunct / noSttPunct | 60 / 30 / 30 |
| endsOpen / dict3plus | 10 / 15 |
| cueCorrection / cuelessCorrection | 12 / 6 |
| filler / repetition / numbers | 12 / 10 / 12 |
| request / question / negation | 38 / 7 / 22 |
| handsFree / en | 5 / 5 |

Each JSONL line has `id`, `category`, `lang`, `purpose`, `critical`, `input`, and `expect`. Input contains `transcript`, `customInstruction`, `dictionary` (entries use `preferred`, `readings`, and `memo`), `outputLanguage`, and `handsFree`. Expectations contain `mustContain`, `mustNotContain`, `language`, `noAnswer`, `reference`, `endsOpen`, `dictionarySurfaces`, and `tags`; `corrections` supplies old/new pairs where applicable. `reference` preserves the spoken wording and order apart from fillers, repetitions, retractions, punctuation, and dictionary spelling. An open ending remains unfinished.
