# The two Nintendo logos, taken from this project's own dumps

Neither identify module checks its cartridge's logo, and both say why: it
needs known-good bytes compiled in, and getting them wrong would reject good
cartridges for a reason nobody could see.

`docs/DUMP-VERIFY-PLAN.md` proposes checking them. This file is the source
for the constants, and the point of it is that these bytes are **not
transcribed from a document**. They are what this hardware read, agreed
across cartridges that have nothing to do with each other.

Regenerate rather than trust:

```sh
# GBA, from any two GBA dumps
python3 -c "a=open('GBAZELDA_MC.gb','rb').read()[4:0xA0]; \
b=open('GOLDEN_SUN_A.gb','rb').read()[4:0xA0]; \
print(a==b, a.hex(' '))"

# GB, from every GB dump at once
python3 -c "import glob;print({open(p,'rb').read()[0x104:0x134] for p in glob.glob('*.gb')}.__len__())"
```

## GBA, 156 bytes at 0x04-0x9F

Byte-identical across `GBAZELDA_MC.gb` (Minish Cap, 16 MB) and
`GOLDEN_SUN_A.gb` (Golden Sun, 8 MB).

    sha1 17daa0fec02fc33c0f6abb549a8b80b6613b48ee

Not circular: nothing in a GBA header covers this region, so neither dump had
its logo verified by anything. They match anyway, which is the evidence.

    24 ff ae 51 69 9a a2 21 3d 84 82 0a
    84 e4 09 ad 11 24 8b 98 c0 81 7f 21
    a3 52 be 19 93 09 ce 20 10 46 4a 4a
    f8 27 31 ec 58 c7 e8 33 82 e3 ce bf
    85 f4 df 94 ce 4b 09 c1 94 56 8a c0
    13 72 a7 fc 9f 84 4d 73 a3 ca 9a 61
    58 97 a3 27 fc 03 98 76 23 1d c7 61
    03 04 ae 56 bf 38 84 00 40 a7 0e fd
    ff 52 fe 03 6f 95 30 f1 97 fb c0 85
    60 d6 80 25 a9 63 be 03 01 4e 38 e2
    f9 a2 34 ff bb 3e 03 44 78 00 90 cb
    88 11 3a 94 65 c0 7c 63 87 f0 3c af
    d6 25 e4 8b 38 0a ac 72 21 d4 f8 07

## GB, 48 bytes at 0x0104-0x0133

Byte-identical across **all fifteen** GB cartridges dumped, spanning ROM-only,
MBC1 and MBC5, from 32 KB to 1 MB.

    sha1 0745fdef34132d1b3d488cfbdf0379a39fd54b4c

Weaker evidence than it looks, and worth being honest about: the boot ROM of a
real Game Boy checks this region, so a cartridge with a wrong logo would not
run and would not be in anyone's collection. Fifteen agreeing confirms the
bytes were read correctly; it does not independently confirm what they should
be. The GBA set is the stronger of the two.

    ce ed 66 66 cc 0d 00 0b 03 73 00 83
    00 0c 00 0d 00 08 11 1f 88 89 00 0e
    dc cc 6e e6 dd dd d9 99 bb bb 67 63
    6e 0e ec cc dd dc 99 9f bb b9 33 3e
