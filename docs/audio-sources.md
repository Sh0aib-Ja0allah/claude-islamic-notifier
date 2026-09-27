# Audio sources for the six adhkar (research input for M5)

> **Written for:** the plugin author, who rules on the `[DECIDE]` items in §7, and whoever prepares the audio at milestone M5.
> **Checked on:** 2026-09-28. Every license below was read on the clip's own page on that date.
> **Pronunciation: not reviewed.** No clip was listened to or downloaded. A native speaker reviews pronunciation at M5 (PLAN.md §7.2, §13 #9).

## 1. Question and scope

PLAN.md §0 (2026-09-28) fixes the audio source:

> Recorded voices from the web, but only freely licensed clips (CC0 or CC BY; the clip's page must say so). Phrases with no licensed clip yet get a temporary synthetic (paid-tier TTS) voice, labelled as such, until a licensed recording is found.

The question for each id: **which is the best clip that meets that rule, and if there is none, where did we look?**

These rules applied:

- **License:** CC0 or CC BY (any version), stated on the clip's own page. CC BY-SA is listed but marked **NEEDS MY OK** (§13 #7). Excluded: CC BY-NC, any ND license, no license, the Public Domain Mark (not CC0 or CC BY), and site licenses that ban standalone redistribution.
- **Wording:** exactly as PLAN.md §0 words it. The salawat must contain «سيدنا».
- **Content:** no Quran, adhan, prayer, anthem, song, sermon, music or effects, and nothing on the PLAN.md §7.4 list. A takbir cut from Eid takbirat or from a prayer is **DECIDE**, never CANDIDATE.
- **Credibility:** a license tag is only the uploader's claim. It counts only if the uploader is plausibly the speaker or recordist and nothing on the page contradicts it.

| id | Target wording (display) | Pausal form (end of a trimmed clip) |
|---|---|---|
| `salawat` | اللَّهُمَّ صَلِّ عَلَى سَيِّدِنَا مُحَمَّدٍ | …مُحَمَّدْ |
| `subhanallah` | سُبْحَانَ اللَّهِ | سُبْحَانَ اللَّهْ |
| `alhamdulillah` | الْحَمْدُ لِلَّهِ | الْحَمْدُ لِلَّهْ |
| `la-ilaha-illallah` | لَا إِلَهَ إِلَّا اللَّهُ | …إِلَّا اللَّهْ |
| `allahu-akbar` | اللَّهُ أَكْبَرُ | اللَّهُ أَكْبَرْ |
| `la-hawla` | لَا حَوْلَ وَلَا قُوَّةَ إِلَّا بِاللَّهِ | …إِلَّا بِاللَّهْ |

## 2. Method

All searching happened on 2026-09-28. The total was about 196 web requests, spaced 2.5–4 s apart. Wikimedia API calls sent the User-Agent `islamic-notifier-license-research/0.1 (https://github.com/Sh0aib-Ja0allah/claude-islamic-notifier)`. License evidence always comes from the clip's own page. Search snippets and index listings were used only to find pages.

**Queries per phrase:**

- the Arabic with and without diacritics;
- the Latin spellings: Allahumma salli (ala sayyidina Muhammad), salawat, Subhanallah / Subhan Allah, Alhamdulillah / Al-hamdu lillah, La ilaha illallah / La ilaha illa Allah, Allahu Akbar / Allah akbar, La hawla (wa la quwwata illa billah), hawqala;
- the English meanings: "blessings upon Muhammad", "Glory be to God", "Praise be to God", "There is no god but God", "God is great", "no power nor strength except".

| # | Source | How it was searched | Result |
|---|---|---|---|
| a | **Wikimedia Commons**, including Lingua Libre `LL-Q…` uploads and Wiktionary `Ar-…` pronunciations | <ul><li>MediaWiki API `list=search`, namespace 6, `filetype:audio`: 33 phrase queries plus 21 `intitle:` token queries (الله, Allah, Allahu, Subhan, سبحان, الحمد, إله, حول, اللهم, salli, ilaha, illallah, hawla, quwwata, takbir, dhikr, zikr, adhkar, …).</li><li>`list=categorymembers` on Takbir, Dhikr, Tasbih, Shahada, La ilaha illallah, Salawat, Alhamdulillah, "Audio files about Islam", "Arabic pronunciation" (1,873 files, filtered by title), "Arabic pronunciation of words relating to Islam" and "La Hawla wa la Quwwata Illa Billah".</li><li>For every hit: `prop=imageinfo` (`extmetadata`, duration), then the `File:` page itself for the license text.</li></ul> | Main source of candidates |
| b | **lingualibre.org** | **NOT SEARCHED directly.** The site is now a JavaScript single-page app, and `https://lingualibre.org/api.php` returns only the app shell (HTTP 200, `text/html`). All 12 queries failed. Lingua Libre publishes its recordings to Commons as `LL-Q…` files, which row (a) searched by title. | Covered through Commons |
| c | **Freesound** | HTML search pages: 24 phrase and meaning queries plus 4 general ones (dhikr, zikr, "arabic words", "islamic prayer phrase"). Opened each relevant sound page, the uploader lists of `ibrahim_baig` and `trynur`, and the "Palabras arabes" pack page (8 sounds). | Several candidates |
| d | **Openverse** (index only) | API `https://api.openverse.org/v1/audio/` with `license=cc0,by`, 7 Latin-spelling queries. Every hit was followed to its Commons or Freesound page. | No new clip; its hits were already found in (a) or (c), plus one excluded Freesound item |
| e | **archive.org** | `advancedsearch.php`, a Latin-spelling OR-query on `mediatype:audio` (1,862 items). The license was filtered locally: 94 items carry a CC0, PD or CC BY `licenseurl`. A query with Arabic terms and one with a license wildcard both failed server-side (`KeyError` / `BACKEND_ERROR`). | Nothing passes the skepticism rule (§4) |
| f | **Other** | <ul><li>Tatoeba API (`api.tatoeba.org/unstable/sentences`, 6 Arabic queries): the sentences exist ("الحمد لله", "سبحان الله", "الله أكبر", "لا إله إلا الله محمد رسول الله") but **none has audio**.</li><li>Two WebSearch discovery queries led to the Commons hawqala category (images only) and to youpronounce.it. Its "Subhan Allah" page text shows **no CC license statement**, so it is not counted.</li></ul> | Nothing usable |

**NEEDS RULING.** These sources have no per-clip page with a license statement. I did not use or download them.

- **Mozilla Common Voice.** A blanket dataset license and no page per clip [UNVERIFIED: not opened]. It does not meet the §0 wording ("the clip's page must say so").
- **Public Domain Mark items on archive.org** (for example `humd-for-rahman`, `adhkar-morning_202007`, `17BerkatSalawatA`). PDM is not CC0 or CC BY. Every such item also fails the credibility or content rules (§4), so ruling on PDM changes nothing today.

**NOT SEARCHED, and the pairs left out** (the request budget was reached):

- **lingualibre.org directly:** all 6 phrases. The site is a JavaScript app, so this was covered only through Commons.
- **Commons:**
  - fully vocalized Arabic for `la-ilaha-illallah`, `allahu-akbar` and `la-hawla`. The vocalized and plain queries returned identical results for the three phrases where both were run, so Commons search seems to ignore diacritics [UNVERIFIED].
  - English "God is great" was run, "Allah is the Greatest" was not.
- **Freesound:**
  - vocalized Arabic for all 6 phrases;
  - the English meanings for `salawat`, `la-ilaha-illallah`, `allahu-akbar` and `la-hawla`. Only "glory be to god arabic" and "praise be to god arabic" were run.
- **Openverse:** Arabic and English-meaning queries for all 6 phrases.
- **archive.org:** Arabic and English-meaning queries for all 6 phrases (the Arabic query failed server-side).
- **Forvo and howtopronounce.com:** not opened. Forvo's user recordings are generally CC BY-NC-SA [UNVERIFIED], which is excluded as NC.

## 3. Candidates

Per clip, M5 needs the speaker, dialect, duration, format and the required attribution. Every row is **pronunciation: not reviewed**.

**Verdicts:** CANDIDATE meets §0 · NEEDS MY OK (BY-SA) is CC BY-SA and needs the author's per-file OK (§13 #7) · DECIDE is the author's call (reason given).

### 3.1 `salawat`

**No clip meets the wording.** Every hit either lacks «اللهم» and «سيدنا» or is a different formula. All of them are listed in §4.

### 3.2 `subhanallah`

| Rank | Page URL | License (quoted from the page) | Attribution | Speaker, dialect | Duration, format | Wording | Credibility | Verdict |
|---|---|---|---|---|---|---|---|---|
| 1 | https://commons.wikimedia.org/wiki/File:LL-Q55633582_(ajp)-Akram_(Fazlake)-sub%C4%A7%C4%81n_%CA%94allah.wav | "This file is made available under the Creative Commons CC0 1.0 Universal Public Domain Dedication." | Not required (CC0). Courtesy credit: "Akram (rec. Fazlake), Lingua Libre, CC0" | Akram (recorder Fazlake); South Levantine Arabic (`ajp`) | 1.21 s, WAV | exact (transcribed "subħān ʔallah") | Lingua Libre record; the recorder uploads a long series of ajp words by this speaker. Nothing contradicts the tag. Pronunciation: not reviewed | CANDIDATE (dialect, §7) |
| 2 | https://freesound.org/people/ibrahim_baig/sounds/788914/ | Page label "Creative Commons 0" (link `http://creativecommons.org/publicdomain/zero/1.0/`). Uploader's note: "You are welcome to use my media without seeking any permission, and you do not need to provide any credit." | Not required (CC0). Courtesy credit: "ibrahim_baig, Freesound, CC0" | ibrahim_baig; dialect not stated | 4.55 s; format not captured | extra words: "wa bihamdihi, subhana-llahi-l-azim" (see Arabic below) | 8 uploads, all dhikr phrases. The page does not say whose voice it is, or whether it is human or synthetic [UNVERIFIED]. Pronunciation: not reviewed | CANDIDATE (trim at M5) |

Extra words in rank 2: `وَبِحَمْدِهِ، سُبْحَانَ اللَّهِ الْعَظِيمِ`

### 3.3 `alhamdulillah`

| Rank | Page URL | License (quoted from the page) | Attribution | Speaker, dialect | Duration, format | Wording | Credibility | Verdict |
|---|---|---|---|---|---|---|---|---|
| 1 | https://commons.wikimedia.org/wiki/File:Ar-%D8%A7%D9%84%D8%AD%D9%85%D8%AF_%D9%84%D9%84%D9%87.ogg | "This file is licensed under the Creative Commons Attribution-Share Alike 3.0 Unported license." | "Ar-الحمد لله.ogg" by ArabicAudios, CC BY-SA 3.0, link to the page and to https://creativecommons.org/licenses/by-sa/3.0; indicate changes | ArabicAudios; "Arabic", dialect not stated | 2.07 s, Ogg | exact | Wiktionary-style pronunciation, uploader = author ("Own work"). Nothing contradicts. Pronunciation: not reviewed | NEEDS MY OK (BY-SA) |
| 2 | https://commons.wikimedia.org/wiki/File:LL-Q55633582_(ajp)-AdrianAbdulBaha-%D8%A7%D9%84%D8%AD%D9%85%D8%AF_%D9%84%D9%84%D9%87.wav | "This file is licensed under the Creative Commons Attribution-Share Alike 4.0 International license." | "AdrianAbdulBaha, Lingua Libre", CC BY-SA 4.0, link and changes | AdrianAbdulBaha; South Levantine (`ajp`) | 1.31 s, WAV | exact | Lingua Libre, speaker = recorder = uploader. Nothing contradicts. Pronunciation: not reviewed | NEEDS MY OK (BY-SA) |
| 3 | https://commons.wikimedia.org/wiki/File:LL-Q9168_(fas)-Afsham23-%D8%A7%D9%84%D8%AD%D9%8E%D9%85%D8%AF%D9%8F_%D9%84%D9%90%D9%84%D9%91%D9%87.wav | "This file is licensed under the Creative Commons Attribution-Share Alike 4.0 International license." | "Afsham23, Lingua Libre", CC BY-SA 4.0, link and changes | Afsham23; **Persian** (`fas`) pronunciation of the phrase | 1.57 s, WAV | exact | Lingua Libre, speaker = uploader. Pronunciation: not reviewed | NEEDS MY OK (BY-SA) |
| 4 | https://commons.wikimedia.org/wiki/File:Nl-alhamdulillah.ogg | "I, the copyright holder of this work, hereby publish it under the following license: This file is made available under the Creative Commons CC0 1.0 Universal Public Domain Dedication." | Not required (CC0) | Marcel coenders; **Dutch** Wiktionary ("Wikiwoordenboek audio") pronunciation of the loanword | 1.75 s, Ogg | exact (Latin spelling) | Uploader = author. Very likely a Dutch-language pronunciation, not an Arabic one. Pronunciation: not reviewed | DECIDE |

### 3.4 `la-ilaha-illallah`

| Rank | Page URL | License (quoted from the page) | Attribution | Speaker, dialect | Duration, format | Wording | Credibility | Verdict |
|---|---|---|---|---|---|---|---|---|
| 1 | https://freesound.org/people/ibrahim_baig/sounds/788913/ | Page label "Creative Commons 0" (link `http://creativecommons.org/publicdomain/zero/1.0/`). Uploader's note as in §3.2 | Not required (CC0) | ibrahim_baig; dialect not stated | 4.75 s; format not captured | extra words **after** the phrase: "Muhammadur rasulullah" | As in §3.2: voice origin not stated [UNVERIFIED]. Pronunciation: not reviewed | CANDIDATE (trim at M5) |
| 2 | https://commons.wikimedia.org/wiki/File:Kalimah1.ogg | "I, the copyright holder of this work, hereby publish it under the following license: This file is licensed under the Creative Commons Attribution 3.0 Unported license." | "Kalimah1.ogg" by Hawk786, CC BY 3.0, link to the page and to https://creativecommons.org/licenses/by/3.0; indicate the trim | Hawk786; dialect not stated | 10.85 s, Ogg | extra words **after** the phrase: "Muhammadur rasulullah". The description says "Recitation of 1st Kalimah", so the delivery style (plain or melodic) is unknown | Uploader = author ("Own work", 2011). Nothing contradicts. Pronunciation: not reviewed | CANDIDATE (trim at M5) |
| 3 | https://commons.wikimedia.org/wiki/File:Shahadah-female_voice.ogg | "I, the copyright holder of this work, hereby publish it under the following license: This file is made available under the Creative Commons CC0 1.0 Universal Public Domain Dedication." | Not required (CC0) | Xhmee; female voice; dialect not stated | 5.64 s, Ogg | extra words **before and after**: "ashhadu an … wa ashhadu anna Muhammadan rasulullah" ("short form" shahada) | Uploader = author, and the file is used on da.wikipedia "Islam". The leading "an" merges into "lā" in speech, so a clean start may be hard. Pronunciation: not reviewed | CANDIDATE (trim at M5) |
| 4 | https://commons.wikimedia.org/wiki/File:Shahadah.ogg | "This file is licensed under the Creative Commons Attribution-Share Alike 3.0 Unported license." and the GFDL: "You may select the license of your choice." | "Shahadah.ogg" by iSurrender, CC BY-SA 3.0, link and changes | iSurrender; dialect not stated | 6.93 s, Ogg | extra words before and after (full shahada) | Uploader Quibik transferred it in 2012; author iSurrender. Pronunciation: not reviewed | NEEDS MY OK (BY-SA) |

Extra words: rank 1 and rank 2 `مُحَمَّدٌ رَسُولُ اللَّهِ` · ranks 3 and 4 `أَشْهَدُ أَنْ … وَأَشْهَدُ أَنَّ مُحَمَّدًا رَسُولُ اللَّهِ`

### 3.5 `allahu-akbar`

| Rank | Page URL | License (quoted from the page) | Attribution | Speaker, dialect | Duration, format | Wording | Credibility | Verdict |
|---|---|---|---|---|---|---|---|---|
| 1 | https://commons.wikimedia.org/wiki/File:LL-Q13955_(ara)-Ajron_Bach-Allahu_Akbar_(noun).wav | "This file is made available under the Creative Commons CC0 1.0 Universal Public Domain Dedication." | Not required (CC0). Courtesy credit: "Ajron Bach, Lingua Libre, CC0" | Ajron Bach (speaker = recorder); Arabic (`ara`) | 1.25 s, WAV | exact | Speaker = uploader. Their other Lingua Libre uploads are mostly English, so this is **probably a non-native Arabic speaker**. Pronunciation: not reviewed | CANDIDATE |
| 2 | https://commons.wikimedia.org/wiki/File:Allahuakbar.opus | "I, the copyright holder of this work, hereby publish it under the following license: This file is made available under the Creative Commons CC0 1.0 Universal Public Domain Dedication." | Not required (CC0) | Bod lnga klang; dialect not stated; categories Takbir, Islam, "Muslims from China" | 2.55 s, Opus | exact (description: "arabic voice of takbir") | "Own work", but the uploader's other files are 2013 Hong Kong photos, and the page does not say where the takbir came from (plain speech, prayer or Eid). Pronunciation: not reviewed | DECIDE |
| 3 | https://commons.wikimedia.org/wiki/File:Ar-eg-%D8%A7%D9%84%D9%84%D9%87_%D8%A3%D9%83%D8%A8%D8%B1.oga | "I, the copyright holder of this work, hereby publish it under the following license: This file is licensed under the Creative Commons Attribution-Share Alike 4.0 International license." | "Ar-eg-الله أكبر.oga" by Assem khidhr, CC BY-SA 4.0, link and changes | Assem khidhr; **Egyptian** (`ar-eg`) | 3.00 s, Ogg | exact | Uploader = author. Nothing contradicts. Pronunciation: not reviewed | NEEDS MY OK (BY-SA) |
| 4 | https://commons.wikimedia.org/wiki/File:LL-Q33549_(jav)-Muhamad_Izzul_Fiqih-Allahu_akbar.wav | "This file is licensed under the Creative Commons Attribution-Share Alike 4.0 International license." | "Muhamad Izzul Fiqih, Lingua Libre", CC BY-SA 4.0, link and changes | Muhamad Izzul Fiqih; recorded as **Javanese** (`jav`) | 1.33 s, WAV | exact | Speaker = uploader. Pronunciation: not reviewed | NEEDS MY OK (BY-SA) |
| 5 | https://freesound.org/people/trynur/sounds/581213/ | Page label "Creative Commons 0" (link `http://creativecommons.org/publicdomain/zero/1.0/`) | Not required (CC0) | trynur; dialect not stated | 3.96 s, MP3 (file name `takbir1.mp3`) | exact (description "Takbitarul Ihram") | Part of a 19-clip series of prayer recitations (rukuk, sujud, tasyahud, salam). **Takbiratul ihram is the opening takbir of the prayer.** Pronunciation: not reviewed | DECIDE |

### 3.6 `la-hawla`

**No clip found** on any source searched. Every hit for the Arabic, the Latin spellings and the meaning was unrelated (§4).

## 4. Excluded

| Clip / item | Page | Reason |
|---|---|---|
| Freesound 788917 "Sale'ala'Muhammad", ibrahim_baig (CC0) | https://freesound.org/people/ibrahim_baig/sounds/788917/ | Wording: `صَلِّ عَلَىٰ مُحَمَّدٍ` only. It lacks «اللهم» and «سيدنا». |
| Freesound 788912 "Laa Tansi ZikrAllah with Salli 'ala Muhammad", ibrahim_baig (CC0) | https://freesound.org/people/ibrahim_baig/sounds/788912/ | Wording: different phrase plus a salawat without «اللهم» and «سيدنا». |
| Freesound 788916 "sallallahu 'alayhi wa sallam", ibrahim_baig | https://freesound.org/people/ibrahim_baig/sounds/ | Wording: a different formula (seen in the uploader's list, not opened). |
| Freesound 788915 "SubhanAllahi wa biHamdihi … with reverb", ibrahim_baig (CC0) | https://freesound.org/people/ibrahim_baig/sounds/788915/ | Effects (reverb). The dry version 788914 is listed in §3.2. |
| `File:LL-Q13955 (ara)-Fjmustak-صلى الله عليه وسلم.wav` (CC BY-SA 4.0) | https://commons.wikimedia.org/wiki/File:LL-Q13955_(ara)-Fjmustak-%D8%B5%D9%84%D9%89_%D8%A7%D9%84%D9%84%D9%87_%D8%B9%D9%84%D9%8A%D9%87_%D9%88%D8%B3%D9%84%D9%85.wav | Wording: a different formula (ﷺ), not the salawat of §0. |
| `File:Muhammad Peace be Upon Him-ar.wav` ("Public domain" tag) | https://commons.wikimedia.org/wiki/File:Muhammad_Peace_be_Upon_Him-ar.wav | Wording: the name plus an honorific. The license is also not CC0 or CC BY. |
| `File:LL-Q36213 (mad)-Anis Ainun-salawat.wav` (CC0) | https://commons.wikimedia.org/wiki/File:LL-Q36213_(mad)-Anis_Ainun-salawat.wav | Wording: the Madurese word "salawat", not the phrase. |
| Freesound 581214 "shalawat.mp3", trynur (CC0) | https://freesound.org/people/trynur/sounds/581214/ | Content: "Shalawat Ibrahimiyah" from the prayer (42 s). The wording is not §0's. |
| Freesound 581200 "iftitah1.mp3", trynur (CC0) | https://freesound.org/people/trynur/sounds/581200/ | Content: the prayer's opening du'a ("Doa Iftitah"), 34.5 s, with many extra words. |
| Freesound 469705 "Allahu Akbar", florianreichelt (CC0) | https://freesound.org/people/florianreichelt/sounds/469705/ | **Probable adhan, unconfirmed.** An 11.1 s travel field recording from a Morocco trip, tagged "pray" and "prayer", not a clean phrase. The page does not say what was recorded, so the adhan cannot be confirmed without listening. It is excluded under the NEVER rule. If you want it considered, it becomes DECIDE. |
| Freesound 845344 "Praise be to God - Alhamdulillah", Ojala.Arabe | https://freesound.org/people/Ojala.Arabe/sounds/845344/ | License: "Attribution NonCommercial 4.0" (NC). |
| Freesound pack "Palabras arabes", other 7 sounds (Ojala.Arabe) | https://freesound.org/people/Ojala.Arabe/packs/45182/ | Wording: the titles are Wa alaykum assalaam, Shukran, Min fadlika, Insha'Allah, As-salaamu alaykum, Ahlan wa Sahlan and Afwan. None is one of the six. |
| Freesound 846658 "Labbayka Allahumma labbayk", Ojala.Arabe | https://freesound.org/people/Ojala.Arabe/sounds/846658/ | NC license; wording (talbiyah). |
| Freesound 255761, 257821 (RTB45); 262229 (The_Sound_Side); 260102 (SDLx) | https://freesound.org/people/RTB45/sounds/255761/ · https://freesound.org/people/RTB45/sounds/257821/ · https://freesound.org/people/The_Sound_Side/sounds/262229/ · https://freesound.org/people/SDLx/sounds/260102/ | Adhan recordings (CC BY), so they are never usable. |
| Freesound 171927, 171928, 172368 (nesibe, CC0) | https://freesound.org/people/nesibe/sounds/171927/ | Sufi zikr ceremony and songs (one with frame drum). Song and music. |
| Freesound 798924 "Dhikr, Trap Soul Instrumental" (kontraamusic) | https://freesound.org/people/kontraamusic/sounds/798924/ | Music; NC. |
| Freesound 477862 (mahammed) | https://freesound.org/people/mahammed/sounds/477862/ | NC; unrelated loop. |
| Freesound 643482 "vocal Arabic terrorist religious" (Duisterwho, CC0 per Openverse) | https://freesound.org/people/Duisterwho/sounds/643482 | Not opened. The uploader frames it as "terrorist", which is not a respectful or usable source for dhikr. |
| `File:LL-Q940486 (pey)-Bangrapip-Allah akbar.wav` (CC BY-SA 4.0) and `…-Allah achbar.wav` | https://commons.wikimedia.org/wiki/File:LL-Q940486_(pey)-Bangrapip-Allah_akbar.wav | Wording: "Allah akbar" (Petjo), not "Allahu akbar". |
| `File:LL-Q13955 (ara)-XANA000-الْحَمْدُ.wav` (CC0) | https://commons.wikimedia.org/wiki/File:LL-Q13955_(ara)-XANA000-%D8%A7%D9%84%D9%92%D8%AD%D9%8E%D9%85%D9%92%D8%AF%D9%8F.wav | Wording: partial ("al-hamdu" only). |
| Single-word Lingua Libre files: `…Fjmustak-الله.wav`, `…Zinou2go-إله.wav`, `…Fjmustak-حول.wav` and similar | https://commons.wikimedia.org/wiki/File:LL-Q13955_(ara)-Fjmustak-%D8%A7%D9%84%D9%84%D9%87.wav | Wording: single words, not the phrases. Splicing words from different takes is not a phrase recording. |
| `File:Ar-shahadah.oga`, `File:As-shahadah.ogg` | https://commons.wikimedia.org/wiki/File:Ar-shahadah.oga | Wording: the word "shahadah", not the phrase. |
| `File:Jawad Syed - Alhamdulilah (Vocal Only Nasheed).flac` (CC BY 3.0) | https://commons.wikimedia.org/wiki/File:Jawad_Syed_-_Alhamdulilah_(Vocal_Only_Nasheed).flac | A song (nasheed, 190 s). |
| `File:Takbir Keliling Karangsari Clering 1445 H (2024).ogg` (CC BY-SA 4.0) | https://commons.wikimedia.org/wiki/File:Takbir_Keliling_Karangsari_Clering_1445_H_(2024).ogg | Eid takbirat street procession, 25 min. By the content rule it would be DECIDE at best; it is also BY-SA and not a clip. |
| Libyan anthem files "Allahu Akbar" (CC0) | https://commons.wikimedia.org/wiki/File:Allahu_Akbar_-_Anthem_of_Gaddafi%27s_Libya.ogg | Anthem. |
| `File:Light Verse (Al-Nur 35).oga`, `File:Kullu nafsin … ringtone … .wav` | https://commons.wikimedia.org/wiki/File:Light_Verse_(Al-Nur_35).oga | Quran recitation. |
| `File:Charbi (1).ogg`, `File:Rosary Spoken Version.ogg`, `File:Nl-rosarium.ogg` and other search noise | — | Unrelated (Hausa "tasbihi" clip, a spoken Wikipedia article on the rosary, etc.). |
| archive.org `dhikr-alhuda-*` (71 items in the result set, tagged CC BY 4.0) | https://archive.org/details/dhikr-alhuda-alhusary-hafs | Quran recitations by named reciters. Excluded by content, whatever the tag says. |
| archive.org `adhkar_201608` | https://archive.org/details/adhkar_201608 | PLAN.md §7.4: tagged CC0, but its description says «جميع الحقوق» ("all rights reserved"). |
| archive.org `Eid_Takbir_619`, `HajjTakbir`, `EidTakbirBySheikhAliAhmedMullah.mp3` | https://archive.org/details/HajjTakbir | Uploaders are recording sites or third parties, not the speakers (Haram imams and a named muezzin), so the tags are not credible. Eid or Hajj takbirat. |
| archive.org `allahu-akbar-sound-effect-download-link`, `humd-for-rahman`, `adhkar-morning_202007`, `17BerkatSalawatA`, `aporee_48810_55565` | https://archive.org/details/allahu-akbar-sound-effect-download-link | Public Domain Mark (not CC0 or CC BY), uploaders not credibly the speakers, and songs or ceremonies. |
| archive.org `Tuhfa_e_SukonShaykhMuhammadAslamNaqashbandiDb` (CC0 tag) | https://archive.org/details/Tuhfa_e_SukonShaykhMuhammadAslamNaqashbandiDb | Talks by a named shaykh, not phrase clips, and the uploader is not credibly the speaker. |
| youpronounce.it "Subhan Allah" | https://youpronounce.it/islamic-prayers/subhan-allah/ | No CC license statement in the page text. |

## 5. Coverage

- `salawat`: **none**, so TTS is needed.
- `subhanallah`: **CC0 found**. Rank 1 is dialectal (ajp); rank 2 needs a trim.
- `alhamdulillah`: **BY-SA only.** A CC0 clip exists, but it is a Dutch-language pronunciation (DECIDE).
- `la-ilaha-illallah`: **CC0 / CC BY found**, all needing a trim (extra words).
- `allahu-akbar`: **CC0 found.**
- `la-hawla`: **none**, so TTS is needed.

## 6. Recommendation

| id | Pick | Why |
|---|---|---|
| `salawat` | **TTS** (labelled synthetic) | No clip with «سيدنا» exists under any license searched. |
| `subhanallah` | Commons `LL-Q55633582 (ajp)-Akram (Fazlake)-subħān ʔallah.wav` (CC0) | Exact wording, CC0, a clean 1.2 s WAV. Fallback: Freesound 788914 trimmed. |
| `alhamdulillah` | Commons `Ar-الحمد لله.ogg` (CC BY-SA 3.0), **if you OK BY-SA**; otherwise **TTS** | Exact wording, and the only clearly Arabic, non-dialect-labelled clip. |
| `la-ilaha-illallah` | Freesound 788913 (CC0), trimmed after «إِلَّا اللَّهُ» | The phrase comes first, so the trim is at the end. CC0. Fallback: `Kalimah1.ogg` (CC BY 3.0) trimmed. |
| `allahu-akbar` | Commons `LL-Q13955 (ara)-Ajron Bach-Allahu Akbar (noun).wav` (CC0) | Exact wording, CC0, a 1.25 s WAV. The speaker is probably non-native, so native review is mandatory. Fallback: TTS. |
| `la-hawla` | **TTS** (labelled synthetic) | Nothing found. |

**Totals: n = 3 licensed** (subhanallah, la-ilaha-illallah, allahu-akbar) **· m = 1 BY-SA pending** (alhamdulillah) **· k = 2 TTS** (salawat, la-hawla). If you decline BY-SA, k = 3.

## 7. [DECIDE]

1. **BY-SA files.** The bundle is not CC0/CC BY only if any of these is accepted. Each needs a per-file OK (§13 #7).
   - `Ar-الحمد لله.ogg` (ArabicAudios, CC BY-SA 3.0). **Recommend: OK.** It is the only non-TTS option for `alhamdulillah`. It needs a `CREDITS.md` row marked BY-SA, and share-alike applies to the processed file.
   - `LL-Q55633582 (ajp)-AdrianAbdulBaha-الحمد لله.wav`, `LL-Q9168 (fas)-Afsham23-الحَمدُ لِلّه.wav`, `Ar-eg-الله أكبر.oga`, `LL-Q33549 (jav)-…-Allahu akbar.wav`, `Shahadah.ogg`. **Recommend: decline.** Each has a better CC0 or CC BY option, or the first pick is preferable.
2. **Mixed speakers vs §13 #3 ("one voice for v0.1").** The recommended set has three different human speakers (Akram, ibrahim_baig, Ajron Bach), possibly a fourth (ArabicAudios), plus a TTS voice. **Recommend: accept mixed voices for v0.1.** It is the only way to follow §0's web-first rule. The loudness matching in §7.2 limits the jarring. The alternative is an all-TTS set in one voice, which contradicts §0's order of preference.
3. **A dialect best clip.** The `subhanallah` pick is South Levantine (`ajp`). **Recommend: accept, subject to native review.** It is a two-word phrase in near-standard form. Otherwise use Freesound 788914 trimmed.
4. **TTS vendor and billing (k = 2, or 3).** `salawat` and `la-hawla`, plus `alhamdulillah` if BY-SA is declined. **Recommend:** one paid-tier vendor for all TTS clips, either Azure S0 `ar-SA-HamedNeural` or Google Cloud `ar-XA`, per PLAN.md §7.3. You must choose it and supply the account (PLAN.md §13 #6).
5. **DECIDE clips.**
   - `Allahuakbar.opus` (CC0; the source of the takbir is not stated). **Recommend: decline**, because an exact CC0 alternative exists.
   - Freesound 581213 `takbir1.mp3` (CC0; takbiratul ihram, from a prayer). **Recommend: decline.**
   - `Nl-alhamdulillah.ogg` (CC0; Dutch pronunciation). **Recommend: decline.**
   - Freesound 469705 (probable adhan, currently in §4). **Recommend: keep excluded.**
6. **Needs ruling.** Mozilla Common Voice (dataset license, no per-clip page) and archive.org Public Domain Mark items. **Recommend: do not use.** Neither meets §0 as worded.

**People who could be contacted.** I cannot contact anyone; you may choose to.

- **ibrahim_baig (Freesound):** confirm the clips are his own human voice. Ask whether he would record the exact salawat with «سيدنا» and «لا حول ولا قوة إلا بالله» under CC0. That could remove both TTS gaps.
- **ArabicAudios (Commons):** ask whether they would relicense `Ar-الحمد لله.ogg` under CC BY 4.0, which removes the BY-SA question.
- **Lingua Libre Arabic speakers, for example Fazlake/Akram (ajp):** ask them to record the missing phrases under CC0.
- **Bod lnga klang (Commons):** ask where `Allahuakbar.opus` was recorded (plain speech, prayer or Eid).
