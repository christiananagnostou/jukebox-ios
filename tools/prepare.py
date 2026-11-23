import argparse
import math
import struct
import wave
import zlib
from pathlib import Path


def main(arguments=None):
    parser = argparse.ArgumentParser(description='Generate authored invented demo fixtures, or explicitly rebuild the icon.')
    parser.add_argument('--icon', action='store_true', help='Rebuild only the existing installation icon')
    args = parser.parse_args(arguments)
    if args.icon:
        from tools.fixtures.icon import build
        build()
        return
    folder=Path(__file__).resolve().parent.parent/'Resources/Fixtures';folder.mkdir(parents=True,exist_ok=True)
    path=folder/'tone.wav'
    if not path.exists():
        with wave.open(str(path),'wb') as stream:
            stream.setparams((2,2,48000,18*48000,'NONE','not compressed'));data=bytearray()
            for i in range(18*48000):
                value=round(600*min(1,i/4800,(18*48000-i)/4800)*math.sin(2*math.pi*220*i/48000));data.extend(struct.pack('<hh',value,value))
            stream.writeframes(data)
    print('Invented demo media ready')

    def png(width,height,sky,horizon):
        rows=bytearray()
        for y in range(height):
            rows.append(0)
            for x in range(width):
                color=sky if y<height*.55 else horizon
                if (x-width*.63)**2+(y-height*.25)**2 < (min(width,height)*.17)**2:color=(225,207,160)
                rows.extend(color)
        def chunk(kind,data):return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
        return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',width,height,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(rows))+chunk(b'IEND',b'')
    cool = ((37, 57, 82), (87, 119, 133))
    warm = ((152, 56, 32), (206, 130, 70))
    for name, width, height, palette in [
        ('wide', 800, 120, cool), ('portrait', 120, 800, warm), ('square', 400, 400, cool),
    ]:
        (folder/(name+'.png')).write_bytes(png(width, height, *palette))

    import subprocess
    from tempfile import TemporaryDirectory
    fixtures=folder.parent.parent/'Tests/JukeboxCoreTests/Fixtures';fixtures.mkdir(exist_ok=True)
    cases = [
        ('bridge.wav', 'pcm_s16le', 24000, 1, []),
        ('bridge.mp3', 'libmp3lame', 24000, 1, ['-b:a', '96000']),
        ('bridge.flac', 'flac', 24000, 1, []),
        ('bridge-aac.aac', 'aac', 44100, 2, ['-b:a', '128000', '-f', 'adts']),
        ('bridge-aac.m4a', 'aac', 44100, 2, ['-b:a', '128000']),
        ('bridge-alac.m4a', 'alac', 48000, 2, ['-sample_fmt', 's32p']),
        ('bridge.aiff', 'pcm_s16be', 32000, 1, ['-f', 'aiff']),
    ]
    for name, codec, rate, channels, options in cases:
        output=fixtures/name
        if output.exists() and output.stat().st_size:
            continue
        with TemporaryDirectory(dir=fixtures) as temporary:
            encoded = Path(temporary) / name
            subprocess.run([
                'ffmpeg', '-hide_banner', '-loglevel', 'error', '-nostdin', '-f', 'lavfi',
                '-i', f'sine=frequency=220:sample_rate={rate}:duration=8',
                '-filter_threads', '1', '-threads', '1', '-ac', str(channels),
                '-c:a', codec, *options, str(encoded),
            ], check=True, timeout=20)
            encoded.replace(output)


if __name__ == '__main__':
    main()
