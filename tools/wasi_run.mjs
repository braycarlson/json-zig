import { readFile } from 'node:fs/promises';
import { argv, env, exit } from 'node:process';
import { WASI } from 'node:wasi';

const wasi = new WASI({
    args: argv.slice(2),
    env,
    preopens: { '.': '.' },
    returnOnExit: true,
    version: 'preview1',
});

const module = await WebAssembly.compile(await readFile(argv[2]));
const instance = await WebAssembly.instantiate(module, wasi.getImportObject());

exit(wasi.start(instance));
