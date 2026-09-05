# Cartridge verification corpus

This is the hardware verification record for physical cartridges dumped with
CartTools. Copyrighted ROM and save data stay in ignored local directories.
Only identity, hashes, hardware metadata, and verification results belong here.

## Pass rules

A cartridge passes only when all applicable rules pass:

1. The ROM CRC32 and byte length match a No-Intro DAT record.
2. A cartridge with a save must load that exact save beside that exact ROM in
   mGBA with the expected visible state.
3. A cartridge expected to contain a save but producing none is an exception,
   not a pass.

`ROM PASS, SAVE PENDING` means only rule 1 has passed. Structural inspection of
a save is useful triage but is never a substitute for rule 2.

## Resolved scan instability

`250d6a0` resolved the intermittent GBA scan failure for the two cartridges
that had been marked unstable. Both produced fresh ROM and save dumps, and all
four files are byte-for-byte repeats of their retained verified artifacts.
The history remains here because it identifies the defect and the hardware
that reproduced it.

| Current status | Cartridge | Hardware identity | Prior ROM evidence | Prior save evidence | Current observation |
|---|---|---|---|---|---|
| PASS ON `250D` | NHL 2002 | GBA `ANLE`, 4 MiB, `EEPROM_V122` | CRC32 `D1D9E515`, SHA-256 `5767e661d887e07ccfeaf91f66f7845378e12070df4b19f86acc785894b22785`, exact No-Intro match | 8 KiB, CRC32 `9A19C12D`, SHA-256 `744c12d54e269afe7b85404d33710a511de87af9c5bc7159552790c8d95be470`; loaded correctly in mGBA | Fresh `250D` ROM and save dumps exactly repeat the prior pair, and the fresh save was visually reconfirmed in mGBA. |
| PASS ON `250D` | Metroid - Zero Mission | GBA `BMXE`, 8 MiB, `SRAM_V113` | CRC32 `5C61A844`, SHA-256 `fc94f65380b65b870a30b9b04b39cca1dc63d6e46a4a373d3904adc0912ebc37`, exact No-Intro match | 32 KiB, CRC32 `6C90074B`, SHA-256 `de92473cc3074a592caa43881240bc755bca2533da2c3be3b6635ab37098da21`; loaded correctly in mGBA | Fresh `250D` ROM and save dumps exactly repeat the prior pair, and the fresh save was visually reconfirmed in mGBA. |

Both cartridges were cleaned again and their contacts appear immaculate. That
makes visible contamination a weaker explanation, but it does not by itself
exclude contact resistance, connector pressure, timing margin, voltage margin,
or a probe sequencing defect. The repeatable native-path boot is evidence
against dead cartridges and narrows the failure to differences between that
path and CartTools.

The rollback test used the archived pre-Quartus-25.1 `e510c8e` bitstream. Its
installed SHA-256 was
`0396d943421a0c7357fb0a15b5efa47fa38a6ffb3e569e4f90b0f7040a9ff54f`,
an exact match to the retained build. Its intermittent results across the wider
GBA cartridge set exclude Quartus 25.1 and the later `e510c8e..fd0fa5c` changes
as the cause. They also show that the fault is not unique to NHL 2002 or Zero
Mission.

Commit `c745719` then added the weak AD-bus pull-ups used by the native GBA
core. Hardware behavior remained unreliable. SimCity 2000, The Minish Cap,
and NHL 2002 each needed multiple manual scans before resolving; Zero Mission
never resolved. This result leaves the broader CartTools identification path
unstable and proves the pull-ups alone are not the fix.

Commit `21a0da6` made the failed stage visible. The reproducing GBA cartridge
reported `GB SAFETY GATE`, with only about one successful recognition in ten
rescans. The gate reads `cart_tran_bank1` as GB `D0-D7`; on a GBA cartridge
those pins are `A16-A23` inputs and are not driven during this safe probe.

Commit `9c55408` put weak pull-ups on the actual bank 1 input. Recognition
improved to roughly four or five scans in ten, confirming the floating path
but not fixing it. Commit `250d6a0` then precharged bank 1 to `FF` while both
GB strobes were inactive and released it during the 200 ns setup before each
read. The same reproducer could not be made to fail under repeated rescans.
The fresh `250D` regression then dumped NHL 2002, Zero Mission, SimCity 2000,
Tetris Plus, and Oracle of Ages. That set includes both previously unstable
GBA cartridges plus GB and GBC controls.

## `250D` safety-gate regression, 2026-09-04

Core commit: `250d6a0`

Local evidence: `build/evidence/250d-safety-regression/`

All five ROMs independently match the current No-Intro DATs on CRC32 and byte
length. NHL 2002 and Zero Mission each produced a fresh save as well, and each
ROM/save pair is byte-for-byte identical to the earlier verified pair. Both
fresh saves were also visually reconfirmed in mGBA. This closes their
`UNSTABLE SCAN` status and passes the scan and dump regression.

The other three retain their corpus qualifications separately. SimCity 2000
has no save file in this capture, so this capture is a save exception even
though its earlier verified save remains valid. Tetris Plus exactly repeats
its earlier save, and that exact save is now verified in mGBA. Oracle of Ages
produced a different save from Batch 5, and that exact new save loaded correctly
in mGBA. No screenshots were present.

### ROMs

| Result | Dump | No-Intro identity | Hardware identity | Bytes | CRC32 | SHA-256 |
|---|---|---|---|---:|---|---|
| PASS | `NHL_2002.gba` | NHL 2002 (USA) | GBA `ANLE`, `EEPROM_V122` | 4,194,304 | `D1D9E515` | `5767e661d887e07ccfeaf91f66f7845378e12070df4b19f86acc785894b22785` |
| ROM PASS, SAVE EXCEPTION | `SIMCITY_2000.gba` | SimCity 2000 (USA) | GBA `A5CE`, `EEPROM_V124` | 4,194,304 | `733751B3` | `02a951f2918e13052f4b28844106093a28a3f9c78739434b1e49a2839babc333` |
| PASS | `TETRIS_PLUS.gb` | Tetris Plus (Japan) (SGB Enhanced) | GB, MBC1+RAM+BAT type `03`, RAM code `02` | 262,144 | `2EC9120A` | `805599a58067cfd10f528d58ce34ae9fc6bba32bbc781dc4bd902fa86028eba4` |
| PASS | `ZELDA_NAYRUAZ8E.gbc` | Legend of Zelda, The - Oracle of Ages (USA, Australia) | GBC, MBC5+RAM+BAT type `1B`, RAM code `02` | 1,048,576 | `3800A387` | `0b56b78a9e45452e98c33edd111234931f1e034dc097f6f23082eb8db6055474` |
| PASS | `ZEROMISSIONE.gba` | Metroid - Zero Mission (USA, Australia) | GBA `BMXE`, `SRAM_V113` | 8,388,608 | `5C61A844` | `fc94f65380b65b870a30b9b04b39cca1dc63d6e46a4a373d3904adc0912ebc37` |

### Save verification

| Dump | Technology | Bytes | CRC32 | SHA-256 | Result |
|---|---|---:|---|---|---|
| `NHL_2002.sav` | EEPROM, `EEPROM_V122` | 8,192 | `9A19C12D` | `744c12d54e269afe7b85404d33710a511de87af9c5bc7159552790c8d95be470` | PASS, freshly loaded correctly in mGBA |
| `SIMCITY_2000.sav` | EEPROM, `EEPROM_V124` | 8,192 expected | | | EXCEPTION, no save file in this capture |
| `TETRIS_PLUS.sav` | MBC1 RAM, one 8 KiB bank | 8,192 | `6E8A645C` | `b3f73935c7519386322ea60211aa104bdbd9be8671453848127c0cc620ffc6f3` | PASS, loaded correctly in mGBA |
| `ZELDA_NAYRUAZ8E.sav` | MBC5 RAM, one 8 KiB bank | 8,192 | `959B27CB` | `b8de140dbdc3c9c7bd7e72e060b018cc7945c3322230c258f8c7933c0990caa1` | PASS, differs from the Batch 5 save and loaded correctly in mGBA |
| `ZEROMISSIONE.sav` | SRAM, `SRAM_V113` | 32,768 | `6C90074B` | `de92473cc3074a592caa43881240bc755bca2533da2c3be3b6635ab37098da21` | PASS, freshly loaded correctly in mGBA |

## Batch 6, 2026-09-04

Core commit: `250d6a0`

Local evidence: `build/evidence/batch-6/` and
`build/evidence/batch-6-yugioh-redump-2/`

All 21 cartridges pass the corpus rules. Every ROM matches a current No-Intro
record on CRC32 and byte length, and every ROM also passes its internal header
checks. Nine cartridges report no save hardware. The other 12 produced saves
of the sizes specified by their cartridge headers.

Eight saves were loaded and checked in mGBA from this capture: Donkey Kong,
Hamster Paradise 2, Super Mario Land 2, Mario's Picross, Moguranya, The Little
Mermaid II: Pinball Frenzy, Sangokushi, and Link's Awakening. The Dragon Quest
Monsters 2, Jinsei Game, Yu-Gi-Oh!, and Oracle of Seasons saves are exact
byte-for-byte matches to captures already checked in mGBA. No screenshots were
present, and no personal save data is recorded here.

The first Yu-Gi-Oh! ROM was rejected at CRC32 `4E015EC4`, and a retry was
rejected at `8B370A91`. Both failed the ROM global checksum and differed
widely from each other. After the cartridge pins were cleaned, the next ROM
matched the known-good dump byte-for-byte at CRC32 `298BD054`. Its save also
matched the previously confirmed capture at CRC32 `6646D2D7`. This sequence
identifies dirty pin contact as the cause of those two failed reads. It also
retains useful evidence that a plausible header alone does not make a dump
safe to accept.

### ROMs

| Result | Dump | No-Intro identity | Hardware identity | Bytes | CRC32 | SHA-256 |
|---|---|---|---|---:|---|---|
| PASS | `BOMBERMAN_GB.gb` | Bomberman GB (Japan) (SGB Enhanced) | GB, MBC1 type `01`, no RAM | 262,144 | `94337D56` | `6d5de1b94660ab41ae82e4130ddb3df44761579a30c7161615a58b2380b20364` |
| PASS | `BOMBER_BOY.gb` | Bomber Boy (Japan) (En) | GB, MBC1 type `01`, no RAM | 131,072 | `EF9595AC` | `4bf5e484e7c0ae4db784560431402b26963ca12eb82eea7cd6587cbbb414402b` |
| PASS | `DONKEY_KONG.gb` | Donkey Kong (Japan, USA) (En) (SGB Enhanced) | GB, MBC1+RAM+BAT type `03`, RAM code `02` | 524,288 | `EDAB3378` | `2781f6b1014336e3318073f162cadd970329c8148fc62b5e795441cd6fd57051` |
| PASS | `DQM2_R_____BQLJ.gbc` | Dragon Quest Monsters 2 - Maruta no Fushigina Kagi - Ruka no Tabidachi (Japan) (SGB Enhanced) (GB Compatible) | GBC, MBC5+RAM+BAT type `1B`, RAM code `03` | 4,194,304 | `2C428A87` | `90517f73231e52fe3ef733e369b8a3464996e785803fdb583398d40689760ab7` |
| PASS | `HAMUPARA2__BHMJ.gbc` | Hamster Paradise 2 (Japan) | GBC, MBC5+RAM+BAT type `1B`, RAM code `02` | 2,097,152 | `542C78B6` | `aa00671d2803d3ef56533577f1d4609572da3cd0c52061ff7262baeb3a060fb1` |
| PASS | `JINSEI_TOMOACJJ.gbc` | Jinsei Game - Tomodachi Takusan Tsukurou yo! (Japan) (SGB Enhanced) (GB Compatible) | GBC, MBC5+RAM+BAT type `1B`, RAM code `02` | 1,048,576 | `C8D46E99` | `f059eec463aefa71a908743f7286e981161c0877a8d61651ecdce68bc26c342a` |
| PASS | `MARIOLAND2.gb` | Super Mario Land 2 - 6-tsu no Kinka (Japan) (Rev 2) | GB, MBC1+RAM+BAT type `03`, RAM code `02` | 524,288 | `29E0911A` | `fe27376d7dfd218c900873bfd0b1ed5cb618b5a2bc9d427c3618ed5382fe5327` |
| PASS | `MARIO_S_PICROSS.gb` | Mario no Picross (Japan) (SGB Enhanced) | GB, MBC1+RAM+BAT type `03`, RAM code `02` | 262,144 | `17533700` | `eb13fba45c077e52b6947d53cd36ff2fa2f79be39004681dc8f3b4bd93743173` |
| PASS | `MOGURANYA.gb` | Moguranya (Japan) (SGB Enhanced) | GB, MBC1+RAM+BAT type `03`, RAM code `02` | 524,288 | `82FCA204` | `7b85e04d1f22931bdb5bfc82ce23a71b8a5c690d3b5ed0b383bf61608f319fc5` |
| PASS | `OTHELLO.gb` | Othello (Japan) (En) | GB, ROM-only type `00`, no RAM | 32,768 | `C17A002E` | `d0d6537f60f4c19f0a74716504c4d51712595f0a6c4bb498e8d53caf2af458eb` |
| PASS | `PNBALFRENZYVM2E.gbc` | Little Mermaid II, The - Pinball Frenzy (USA) (En,Fr,De,Es,It) (Rumble Version) | GBC, MBC5+RUMBLE+RAM+BAT type `1E`, RAM code `02` | 1,048,576 | `364F9CCD` | `e9e3b8f82c84aabf06f5061567fa23d1bfacb1c2d5cb83e31d93e0cd04716728` |
| PASS | `SANGOKUSHI.gb` | Sangokushi - Game Boy Ban (Japan) | GB, MBC1+RAM+BAT type `03`, RAM code `02` | 262,144 | `83706E92` | `a9b8c50c84b6f33ec29025a76420d5ad098d6b1b99ea9798976d758755f73256` |
| PASS | `SUPER_MARIOLAND.gb` | Super Mario Land (World) (Rev 1) | GB, MBC1 type `01`, no RAM | 65,536 | `2C27EC70` | `49fbd2f61f953d5ef28cab73e357e524c3009ad19fcf30f6a9ee0ae273be41dc` |
| PASS | `TENNIS.gb` | Tennis (World) | GB, ROM-only type `00`, no RAM | 32,768 | `5009215F` | `cdcb6ba23ea2c32a2af47abb267d8bd065a8bc10777b435de6a9be421e5bf919` |
| PASS | `TETRIS.gb` | Tetris (World) (Rev 1) | GB, ROM-only type `00`, no RAM | 32,768 | `46DF91AD` | `0d6535aef23969c7e5af2b077acaddb4a445b3d0df7bf34c8acef07b51b015c3` |
| PASS | `TETRIS_FLASH.gb` | Tetris Flash (Japan) (SGB Enhanced) | GB, MBC1 type `01`, no RAM | 131,072 | `9DFCB385` | `fe9eb6e38a2a16de78713254da361543070d91a49b986a50158b88f0328e6391` |
| PASS | `TYCORAT1___BTIE.gbc` | Racin' Ratz (USA) | GBC, MBC5 type `19`, no RAM | 1,048,576 | `D6881014` | `664a532bbaef3f044ceeda8ce696f1a24cdb613525e8990cea0fb6458c067d9d` |
| PASS | `UNO2SMALL_WORLD.gb` | Uno 2 - Small World (Japan) (SGB Enhanced) | GB, MBC1 type `01`, no RAM | 131,072 | `A7AD65EF` | `88773be9e71529b35ce03d39f417e866f48df97cdfb894943f729dab7beefb90` |
| PASS | `YUGIOUDM4J_BY6J.gbc` | Yu-Gi-Oh! Duel Monsters 4 - Battle of Great Duelist - Jounouchi Deck (Japan) | GBC, MBC5+RAM+BAT type `1B`, RAM code `02` | 4,194,304 | `298BD054` | `734b915b1d408d7e647757ccfcc019295e1280e7d5d77e1764b6a9c7ca334670` |
| PASS | `ZELDA.gb` | Legend of Zelda, The - Link's Awakening (USA, Europe) | GB, MBC1+RAM+BAT type `03`, RAM code `02` | 524,288 | `8CF27C90` | `21f712e213f43f9efb93ca039a5190fc09325d5d932af1fb2f8e90b4f9fd169f` |
| PASS | `ZELDA_DIN__AZ7E.gbc` | Legend of Zelda, The - Oracle of Seasons (USA, Australia) | GBC, MBC5+RAM+BAT type `1B`, RAM code `02` | 1,048,576 | `D7E9F5D7` | `862a51368fb30539279d336b3fe193b43876d2cb15c87a36f5da517804ab3971` |

### Save verification

| Dump | Technology | Bytes | CRC32 | SHA-256 | Result |
|---|---|---:|---|---|---|
| `DONKEY_KONG.sav` | MBC1 RAM, one 8 KiB bank | 8,192 | `CC13720B` | `266ee19fa4c960cea9a3c07eaa2626bce1489efef022541974f799ca8cfc044a` | PASS, loaded correctly in mGBA |
| `DQM2_R_____BQLJ.sav` | MBC5 RAM, four 8 KiB banks | 32,768 | `08BE7E23` | `07fd548dfc50858c77ae7e44c1d8232564a027cfce518cb4866583c339a11077` | PASS, exact repeat of a previously confirmed save |
| `HAMUPARA2__BHMJ.sav` | MBC5 RAM, one 8 KiB bank | 8,192 | `03AA0B0A` | `e2d75f6cfb8d68dc20df854c9fb68f4beec57985591456b4ccd9982a2468be04` | PASS, loaded correctly in mGBA |
| `JINSEI_TOMOACJJ.sav` | MBC5 RAM, one 8 KiB bank | 8,192 | `A6F62B50` | `c0419d0ed61e075fc7eae21240135887db9cb71bf9f4ac2ad458ad3d719389f0` | PASS, exact repeat of a previously confirmed save |
| `MARIOLAND2.sav` | MBC1 RAM, one 8 KiB bank | 8,192 | `6EB28307` | `34171386b3bb5b30b99d197b5bc5038c177f3b25cd59d86dfa5cdaf1842ad28c` | PASS, loaded correctly in mGBA |
| `MARIO_S_PICROSS.sav` | MBC1 RAM, one 8 KiB bank | 8,192 | `B54ADB6C` | `f9bc1e3621b0170aa082dead207fefe7d53cb48eee3eaf0fa670069361dbaa23` | PASS, loaded correctly in mGBA |
| `MOGURANYA.sav` | MBC1 RAM, one 8 KiB bank | 8,192 | `A910880D` | `e29950853de4a6890c7efc0d20eddc39ddda394a3baec879558261436c60c1ee` | PASS, loaded correctly in mGBA |
| `PNBALFRENZYVM2E.sav` | MBC5 rumble RAM, one 8 KiB bank | 8,192 | `5EC85AF5` | `8a71d01e72b81ad5de675b01831e3b7741d92b4fff4436dc2874adb101d19269` | PASS, loaded correctly in mGBA |
| `SANGOKUSHI.sav` | MBC1 RAM, one 8 KiB bank | 8,192 | `5D074EE3` | `70516e40e7738c5838f8bc837d1ff47e96cc1b0b72c4bc27cbfc0ee81b8bb3b7` | PASS, loaded correctly in mGBA |
| `YUGIOUDM4J_BY6J.sav` | MBC5 RAM, one 8 KiB bank | 8,192 | `6646D2D7` | `5a29a36a0d1cf4dd5c59a2dddbf2530fedf03d990da5c099ee88ad95a4c7a025` | PASS, exact repeat of a previously confirmed save |
| `ZELDA.sav` | MBC1 RAM, one 8 KiB bank | 8,192 | `19CCD1B4` | `d558d7f9400861fb3398eeb455be30b889ef8c021ce533a203535b3bc3729cae` | PASS, loaded correctly in mGBA |
| `ZELDA_DIN__AZ7E.sav` | MBC5 RAM, one 8 KiB bank | 8,192 | `57193E99` | `71f20fe37dc84600733db4ad56a30e629332d337a07d09bd0e0311a4f027fea7` | PASS, exact repeat of a previously confirmed save |

## Batch 1, 2026-09-03

Core commit: `ff8c8f0`

Local evidence: `build/corpus/batch-01/`

All 12 ROMs pass their platform header checks and match No-Intro on CRC32 and
byte length. Five cartridges do not contain save hardware and pass without
intervention. Super Mario Advance, Kirby, A Link to the Past and Four Swords,
Harry Potter, Super Mario Bros. Deluxe, Magical Quest, and Shrek also pass with
their exact saves verified in mGBA. All 12 cartridges pass. There are no
missing-save exceptions in this batch.

For the four GBA no-save results, the ROM contains no standard Nintendo SDK
save signature and the EZ-Flash Omega cartridge table records save mode `0x00`.
The GB Color no-save result comes directly from its cartridge header. The
[EZ-Flash table](https://github.com/ez-flash/omega-kernel/blob/master/source/saveMODE.h)
is supporting evidence, while the physical dump and No-Intro record remain the
corpus identity.

### ROMs

| Result | Dump | No-Intro identity | Hardware identity | Bytes | CRC32 | SHA-256 |
|---|---|---|---|---:|---|---|
| PASS | `AGB_KIRBY_DX.gba` | Kirby - Nightmare in Dream Land (USA) | GBA `A7KE`, `SRAM_V112` | 8,388,608 | `20EF3F64` | `caa4e11b6102257939297710dc4b49f6cec307de67838b2e7b7627e81b155db8` |
| PASS | `BUGSBUNNY_CC3.gbc` | Bugs Bunny - Crazy Castle 3 (USA, Europe) (GB Compatible) | GBC, MBC5 type `19`, RAM code `00` none | 1,048,576 | `7A2801FB` | `89e43fdc94ec1d2a67aaab39d72afa50dd01df4323df7bf3d0909247cc490c24` |
| PASS | `DISNEY_PRINC.gba` | Disney Princess (USA, Europe) | GBA `AQPE`, no save | 8,388,608 | `4A2B9E0B` | `7ead87670840e54224dcd96c4f9a9c53df3d60e74a2dd0319928f46a2c8ab5b5` |
| PASS | `GBAZELDA.gba` | Legend of Zelda, The - A Link to the Past & Four Swords (USA) | GBA `AZLE`, `EEPROM_V122` | 8,388,608 | `8E91CD13` | `f328f8f07d736288a00c80d31cc1630f3aa02aaf20efdcba73d31dae832b5d76` |
| PASS | `HARRY_POTTER.gba` | Harry Potter and the Sorcerer's Stone (USA, Europe) | GBA `AHRE`, `EEPROM_V122` | 8,388,608 | `F755065C` | `9532eeccbeeb09e36706b53a362239f9db59935799b62d089e93f9d5381058d8` |
| PASS | `MARIO_DELUXAHYE.gbc` | Super Mario Bros. Deluxe (Europe) (Rev 2) | GBC, MBC5+RAM+BAT type `1B`, RAM code `02` | 1,048,576 | `62BBAE83` | `c06af1a1c2a804e4169fd9bfd6eee7073545d88c97febc96c345dd10efd77547` |
| PASS | `MIC_MIN_MA.gba` | Magical Quest Starring Mickey & Minnie (USA) | GBA `A3ME`, `EEPROM_V122` | 4,194,304 | `B4294FA7` | `47a1a511ba49ec4d205706bde17bdd146e094bee3197470312be72d20b128814` |
| PASS | `NAMCOMUSEUM.gba` | Namco Museum (USA) | GBA `ANME`, no save | 4,194,304 | `C58A04C1` | `c050b53427fd25dbbd57d04ec34c3010a049672540433dca866287d5226a9f5d` |
| PASS | `PIGLET_SGAME.gba` | Piglet's Big Game (USA) | GBA `A9NE`, no save | 8,388,608 | `52919538` | `c4a376d0ce016976e8ec62efc01d620cc3118a5940e94e18d61db84b3cbf8b29` |
| PASS | `SHREK_HATC.gba` | Shrek - Hassle at the Castle (USA) | GBA `AH4E`, `EEPROM_V122` | 4,194,304 | `09E7472C` | `e716bce02239bfc87b3a2b84294dc6b92d877afa0140a3e5a2425b0657bd0c88` |
| PASS | `SUPER_MARIOA.gba` | Super Mario Advance (USA, Europe) | GBA `AMAE`, `EEPROM_V120` | 4,194,304 | `1E4C6D6A` | `d29dec02caacbf449e2a93c6042258b0669542e102eb0e6fd0eb92a5411e0244` |
| PASS | `TETRISWORLDS.gba` | Tetris Worlds (USA) | GBA `ATWE`, no save | 4,194,304 | `7B729804` | `87a857dee5dfb5d48c706abbc103fa148461abc58833c8336cf11f21bcf5ed2a` |

### Save verification

| Dump | Technology | Bytes | CRC32 | SHA-256 | Result |
|---|---|---:|---|---|---|
| `AGB_KIRBY_DX.sav` | SRAM, `SRAM_V112` | 32,768 | `719220B2` | `57d710897d20c1c46421e9ed9050d14daa096af824d46fe9ff3c7c10d06d7bcb` | PASS |
| `GBAZELDA.sav` | EEPROM, `EEPROM_V122` | 8,192 | `341D8A55` | `4a5cfb9e5cde7e8b9708cb64a0e1059d1c34d027678df1f110f837118158503b` | PASS |
| `HARRY_POTTER.sav` | EEPROM, `EEPROM_V122` | 512 | `651A78FB` | `59f258e8a24a580662b42d0e1e435fe91ec7e5475e9916dd8a76cb56806b5193` | PASS: bad interface on the game, but the save looks good |
| `MARIO_DELUXAHYE.sav` | MBC5 RAM, one 8 KiB bank | 8,192 | `254CCCED` | `72892dc23004d8c083165dddf34606f6da60d58f00bf1871edf196b2757aca88` | PASS |
| `MIC_MIN_MA.sav` | EEPROM, `EEPROM_V122` | 512 | `D4EB2716` | `8989905de9583a55cfd56ec0202b073fc73573a95507a83f1ba7afda40a6d811` | PASS |
| `SHREK_HATC.sav` | EEPROM, `EEPROM_V122` | 512 | `A135CE0D` | `a448bc2e251b367a9996b5dd282686ad4bef900960a30af59ac0494794003d12` | PASS |
| `SUPER_MARIOA.sav` | EEPROM, `EEPROM_V120` | 512 | `E7943192` | `5bc6984153daab26abd9175e2eb662502008d56387c467f7b1d30c62a34709bd` | PASS |

The older categorized `Tetris Worlds (USA).sav` is 65,536 bytes of `FF` only.
It is an empty emulator allocation and is not evidence that the physical
cartridge contains save hardware.

## Batch 2, 2026-09-03

Core commit: `ff8c8f0`

Local evidence: `build/corpus/batch-02/`

Collection stopped after two cartridges because the core exposed a visible UI
defect and a behavioral defect. Both collected ROMs pass their platform header
checks and match No-Intro on CRC32 and byte length. Both cartridges produced
nonblank saves of the sizes required by their cartridge headers. Both saves
pass verification. Batch 2 closes at two of two cartridges passing, with no
missing-save exceptions.

### ROMs

| Result | Dump | No-Intro identity | Hardware identity | Bytes | CRC32 | SHA-256 |
|---|---|---|---|---:|---|---|
| PASS | `ZELDA.gbc` | Legend of Zelda, The - Link's Awakening DX (USA, Europe) (Rev 1) (SGB Enhanced) (GB Compatible) | GBC, MBC5+RAM+BAT type `1B`, RAM code `03` | 1,048,576 | `B38EB9DE` | `6285ba6201f17bc8595c600ebc2477d52561f0aff29b11f7fc3343bacb2e230b` |
| PASS | `ZELDA_DIN__AZ7E.gbc` | Legend of Zelda, The - Oracle of Seasons (USA, Australia) | GBC, MBC5+RAM+BAT type `1B`, RAM code `02` | 1,048,576 | `D7E9F5D7` | `862a51368fb30539279d336b3fe193b43876d2cb15c87a36f5da517804ab3971` |

### Save verification

| Dump | Technology | Bytes | CRC32 | SHA-256 | Result |
|---|---|---:|---|---|---|
| `ZELDA.sav` | MBC5 RAM, four 8 KiB banks | 32,768 | `E8BBE64B` | `a172e041e2a6f158aa79a603b88fb1860ae5fc25ce80bd23700d346543e0958c` | PASS |
| `ZELDA_DIN__AZ7E.sav` | MBC5 RAM, one 8 KiB bank | 8,192 | `57193E99` | `71f20fe37dc84600733db4ad56a30e629332d337a07d09bd0e0311a4f027fea7` | PASS |

## Batch 3, 2026-09-03

Core commit: `ad36998`

Local evidence: `build/evidence/batch-3-bug/`

Collection stopped after one cartridge because completing its ROM dump removed
the previously available save action. The ROM is a repeat identity from Batch 1
and passes its header checks plus No-Intro CRC32 and byte-length matching. No
save file was produced. Because this ROM contains `EEPROM_V122` and is expected
to have an 8 KiB save, this observation is a save exception and the cartridge
does not pass Batch 3.

The failure is in control flow rather than ROM data. Pre-dump cartridge
revalidation clears the completed GBA save-signature scan. The ROM dump then
interrupts the replacement scan, leaving no valid result to make the save
action available afterward.

### ROMs

| Result | Dump | No-Intro identity | Hardware identity | Bytes | CRC32 | SHA-256 |
|---|---|---|---|---:|---|---|
| ROM PASS, SAVE EXCEPTION | `GBAZELDA.gba` | Legend of Zelda, The - A Link to the Past & Four Swords (USA) | GBA `AZLE`, `EEPROM_V122` | 8,388,608 | `8E91CD13` | `f328f8f07d736288a00c80d31cc1630f3aa02aaf20efdcba73d31dae832b5d76` |

### Save verification

| Expected dump | Technology | Expected bytes | Result |
|---|---|---:|---|
| `GBAZELDA.sav` | EEPROM, `EEPROM_V122` | 8,192 | EXCEPTION: save action disappeared after the ROM dump; no file produced |

## Batch 4 control, 2026-09-03

Core commit: `fd0fa5c`

Local evidence: `build/evidence/batch-4-control/`

The single Batch 3 cartridge was repeated as the control for the save-scan
restart fix. Its ROM dump completed, the save action returned without a manual
rescan, and the 8 KiB save dump completed. The hardware screenshot carries
build stamp `FD0F`, identifies `GBAZELDA.sav`, reports 8 KiB and CRC32
`33DCC739`, and still shows the save action after completion. The new save
loaded in mGBA with the expected visible state. The control cartridge passes.

### ROMs

| Result | Dump | No-Intro identity | Hardware identity | Bytes | CRC32 | SHA-256 |
|---|---|---|---|---:|---|---|
| PASS | `GBAZELDA.gba` | Legend of Zelda, The - A Link to the Past & Four Swords (USA) | GBA `AZLE`, `EEPROM_V122` | 8,388,608 | `8E91CD13` | `f328f8f07d736288a00c80d31cc1630f3aa02aaf20efdcba73d31dae832b5d76` |

### Save verification

| Dump | Technology | Bytes | CRC32 | SHA-256 | Result |
|---|---|---:|---|---|---|
| `GBAZELDA.sav` | EEPROM, `EEPROM_V122` | 8,192 | `33DCC739` | `8c18f0658bbf652204c6259d8b2af2c58330dc12e9c4ccaf3d5d3d1f85c071f5` | PASS |

## Batch 5, 2026-09-03

Core commit: `fd0fa5c`

Local evidence: `build/evidence/batch-5-unstable/`

Eight ROM and save pairs were retained from the card before analysis. All
eight ROM artifacts pass independent header checks and match a No-Intro record
on CRC32 and byte length. Five cartridges pass the complete corpus rules.
Tetris Plus has a valid ROM and a structurally plausible 8 KiB save, but no
recognizable saved state was available for confirmation. NHL 2002 and Metroid:
Zero Mission retain valid earlier dumps and saves, but repeated scans on the
current core now fail as described in the unstable-cartridge section above.

The installed card bitstream matched the `fd0fa5c` build exactly at SHA-256
`073579d46d400423ceecf37f43667b1bdf0408619d819cc31a43fc3e47a80905`.
The two device screenshots capture the two observed failure classes:
unrecognized cartridge and unstable read requiring a reseat.

Minish Cap and Golden Sun are byte-for-byte repeats of saves already loaded
successfully in mGBA. SimCity 2000, Oracle of Seasons, and Oracle of Ages were
loaded from this capture and confirmed. The two Oracle saves differ from the
earlier retained states, which distinguishes this capture even though each ROM
is the same published revision. Oracle of Seasons changed from CRC32
`57193E99` to `578830B7`; Oracle of Ages changed from `959B27CB` to `8A73D6F1`.

### ROMs

| Result | Dump | No-Intro identity | Hardware identity | Bytes | CRC32 | SHA-256 |
|---|---|---|---|---:|---|---|
| PASS | `GBAZELDA_MC.gba` | Legend of Zelda, The - The Minish Cap (USA) | GBA `BZME`, `EEPROM_V124` | 16,777,216 | `ABCEBBB1` | `bedc74df62755f705398273de8ed3bc59be610cf55760d0b9aa277f1f5035e73` |
| PASS | `GOLDEN_SUN_A.gba` | Golden Sun (USA, Europe) | GBA `AGSE`, `FLASH_V123` | 8,388,608 | `E1FB68E8` | `c14f1151897e8d73f25ffdd67e21eebb6dc57973ff2458872ee89fa9060aaca1` |
| UNSTABLE SCAN, RETAINED ROM VALID | `NHL_2002.gba` | NHL 2002 (USA) | GBA `ANLE`, `EEPROM_V122` | 4,194,304 | `D1D9E515` | `5767e661d887e07ccfeaf91f66f7845378e12070df4b19f86acc785894b22785` |
| PASS | `SIMCITY_2000.gba` | SimCity 2000 (USA) | GBA `A5CE`, `EEPROM_V124` | 4,194,304 | `733751B3` | `02a951f2918e13052f4b28844106093a28a3f9c78739434b1e49a2839babc333` |
| ROM PASS, SAVE UNVERIFIED | `TETRIS_PLUS.gb` | Tetris Plus (Japan) (SGB Enhanced) | GB, MBC1+RAM+BAT type `03`, RAM code `02` | 262,144 | `2EC9120A` | `805599a58067cfd10f528d58ce34ae9fc6bba32bbc781dc4bd902fa86028eba4` |
| PASS | `ZELDA_DIN__AZ7E.gbc` | Legend of Zelda, The - Oracle of Seasons (USA, Australia) | GBC, MBC5+RAM+BAT type `1B`, RAM code `02` | 1,048,576 | `D7E9F5D7` | `862a51368fb30539279d336b3fe193b43876d2cb15c87a36f5da517804ab3971` |
| PASS | `ZELDA_NAYRUAZ8E.gbc` | Legend of Zelda, The - Oracle of Ages (USA, Australia) | GBC, MBC5+RAM+BAT type `1B`, RAM code `02` | 1,048,576 | `3800A387` | `0b56b78a9e45452e98c33edd111234931f1e034dc097f6f23082eb8db6055474` |
| UNSTABLE SCAN, RETAINED ROM VALID | `ZEROMISSIONE.gba` | Metroid - Zero Mission (USA, Australia) | GBA `BMXE`, `SRAM_V113` | 8,388,608 | `5C61A844` | `fc94f65380b65b870a30b9b04b39cca1dc63d6e46a4a373d3904adc0912ebc37` |

### Save verification

| Dump | Technology | Bytes | CRC32 | SHA-256 | Result |
|---|---|---:|---|---|---|
| `GBAZELDA_MC.sav` | EEPROM, `EEPROM_V124` | 8,192 | `12F60F2F` | `2fb51f21588769f0183d8ead956758d3812397d8f6370458dd639b617c83fad0` | PASS, exact repeat of previously verified save |
| `GOLDEN_SUN_A.sav` | Flash, `FLASH_V123` | 65,536 | `32F42D38` | `19b1a8cb1b759658e9add2920d92959636ae86fbc451eafcb28c8a668ad8641d` | PASS, exact repeat of previously verified save |
| `NHL_2002.sav` | EEPROM, `EEPROM_V122` | 8,192 | `9A19C12D` | `744c12d54e269afe7b85404d33710a511de87af9c5bc7159552790c8d95be470` | Prior save remains valid; current scan unstable |
| `SIMCITY_2000.sav` | EEPROM, `EEPROM_V124` | 8,192 | `4CBD7F34` | `20469f06e21f5d0f4fb8705a364162d9e405cc3d95d9df03cf930ef198f62020` | PASS |
| `TETRIS_PLUS.sav` | MBC1 RAM, one 8 KiB bank | 8,192 | `6E8A645C` | `b3f73935c7519386322ea60211aa104bdbd9be8671453848127c0cc620ffc6f3` | UNVERIFIED: no recognizable state; a depleted battery is possible but unproven |
| `ZELDA_DIN__AZ7E.sav` | MBC5 RAM, one 8 KiB bank | 8,192 | `578830B7` | `64c580011d68b04bbb1e2521b4fa03c53f3c83496209cdae0736b639964b593a` | PASS |
| `ZELDA_NAYRUAZ8E.sav` | MBC5 RAM, one 8 KiB bank | 8,192 | `8A73D6F1` | `6c2dbd09b017f496ed94eee4daa3188d7795671ec51a53bbcf901e6e5c2f9b37` | PASS |
| `ZEROMISSIONE.sav` | SRAM, `SRAM_V113` | 32,768 | `6C90074B` | `de92473cc3074a592caa43881240bc755bca2533da2c3be3b6635ab37098da21` | Prior save remains valid; current scan unstable |
