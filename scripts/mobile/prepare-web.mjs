#!/usr/bin/env node

import { cp, mkdir, rm } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../', import.meta.url));
const source = fileURLToPath(new URL('../../app/', import.meta.url));
const destination = fileURLToPath(new URL('../../dist/mobile/', import.meta.url));

if (!destination.startsWith(`${root}dist/`)) {
  throw new Error('Refusing to prepare mobile assets outside dist/.');
}

await rm(destination, { recursive: true, force: true });
await mkdir(destination, { recursive: true });
await cp(source, destination, { recursive: true, force: true });

process.stdout.write(`Prepared canonical app/ assets in ${destination}\n`);
