#!/usr/bin/env python3
"""Package MXZ client source using Python's standard library."""
import argparse
from pathlib import Path
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--audio-dir', type=Path, help='Directory containing licensed death_0.wav through death_12.wav')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    sources = [(p, p.relative_to(root / 'client').as_posix())
               for p in sorted((root / 'client').rglob('*')) if p.is_file()]
    if any(p.suffix.lower() == '.wav' for p, _ in sources):
        parser.error('Keep audio outside client/ and supply it explicitly with --audio-dir')
    for name in ('LICENSE', 'THIRD_PARTY_NOTICES.md', 'SOURCE.md'):
        sources.append((root / name, name))
    if args.audio_dir:
        audio = [args.audio_dir.resolve() / f'death_{i}.wav' for i in range(13)]
        missing = [p.name for p in audio if not p.is_file()]
        if missing:
            parser.error('Missing audio: ' + ', '.join(missing))
        sources.extend((p, 'art/sound/GForceKO/' + p.name) for p in audio)
    else:
        print('Audio omitted: supply licensed files with --audio-dir to include death sounds.')
    output = root / 'dist' / 'MXZ.zip'
    output.parent.mkdir(exist_ok=True)
    # Write atomically and use stable entry metadata for reproducible archives.
    temporary = output.with_suffix('.zip.tmp')
    try:
        with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            for path, name in sorted(sources, key=lambda pair: pair[1]):
                if path.is_symlink():
                    parser.error('Symlink sources are not supported: ' + name)
                info = zipfile.ZipInfo(name, date_time=(2026, 11, 11, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o100644 << 16
                archive.writestr(info, path.read_bytes())
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)
    print(f'Built {output} ({len(sources)} files)')


if __name__ == '__main__':
    main()
