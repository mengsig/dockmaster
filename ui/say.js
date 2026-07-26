// say.js - append a dockmaster reply to the console transcript.
//
// Text arrives on stdin, never argv: a reply is prose and would otherwise be one
// quoting mistake away from being reinterpreted by the shell.

'use strict';

const fs = require('node:fs');

const chat = require('./chat');

function main() {
  const dmHome = process.env.DM_HOME;
  if (!dmHome || !fs.existsSync(dmHome)) {
    throw new Error(`console: DM_HOME is unset or missing ('${dmHome}') - run via bin/dm-ui.sh`);
  }
  const text = fs.readFileSync(0, 'utf8');
  const message = chat.append(dmHome, 'dockmaster', text);
  process.stdout.write(`posted ${message.at}\n`);
}

main();
