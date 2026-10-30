// SPDX-License-Identifier: MIT
//! chumby-image: builds the images the chumby-classic machine (QEMU
//! with qemu-chumby; see ../README.md) boots from: a settings partition
//! and a whole NAND chip.

mod image;

use std::process::ExitCode;

const USAGE: &str = "\
usage: chumby-image mkpsp DIR OUT        JFFS2 image of a settings directory
       chumby-image mknand BACKUP PSP OUT
                     a full NAND image: the partitions from a backup's
                     nanddumps, PSP (a JFFS2 image) as the settings
                     partition, and the Cache partition erased

BACKUP holds the mtdN-*.nanddump files nanddump writes for each partition
of your own Chumby's flash. mknand's OUT is the whole 64 MiB chip in
nanddump's layout: 131072 records of a page's 512 data bytes then its 16
spare (OOB) bytes, 69206016 bytes in all.

A fresh, factory-like settings DIR for mkpsp:
  hostname              chumby
  timezone, localtime   UTC, and the root disk's own UTC zone file
  ts_settings           0,4095,4095,-4095,0: the ADC's full range, which
                        the emulated touchscreen reports against
  firsttime             0, so the boot keeps that calibration
  volume, mute, pan     50, 0, 0

The kernel is the zImage at the start of the Kernel1 partition; its
length is the word at offset 0x2c of its header:
  head -c $((0xLENGTH)) BACKUP/mtd4-Kernel1.bin > zImage
";

fn mkpsp(dir: &str, out: &str) -> Result<(), String> {
    let psp = image::PARTITIONS[1].2;
    let img = image::mkjffs2(std::path::Path::new(dir), psp)?;
    std::fs::write(out, img).map_err(|e| format!("{out}: {e}"))
}

fn mknand(backup: &str, psp: &str, out: &str) -> Result<(), String> {
    let read = |p: String| std::fs::read(&p).map_err(|e| format!("{p}: {e}"));
    let mut parts = Vec::new();
    for (name, _, _) in image::PARTITIONS {
        parts.push(match name {
            "mtd1-PSP" => image::Source::Data(read(psp.to_string())?),
            "mtd6-Cache" => image::Source::Erased,
            _ => image::Source::Dump(read(format!("{backup}/{name}.nanddump"))?),
        });
    }
    let chip = image::mknand(parts)?;
    std::fs::write(out, chip).map_err(|e| format!("{out}: {e}"))
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let r = match args.first().map(String::as_str) {
        Some("-h" | "--help") => {
            print!("{USAGE}");
            return ExitCode::SUCCESS;
        }
        Some("mkpsp") if args.len() == 3 => mkpsp(&args[1], &args[2]),
        Some("mknand") if args.len() == 4 => mknand(&args[1], &args[2], &args[3]),
        _ => Err(USAGE.into()),
    };
    match r {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    }
}
