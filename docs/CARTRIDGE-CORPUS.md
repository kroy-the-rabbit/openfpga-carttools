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
