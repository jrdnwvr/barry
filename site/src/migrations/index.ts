import * as migration_20261003_154350_initial from './20261003_154350_initial';
import * as migration_20261003_155338_ipad from './20261003_155338_ipad';

export const migrations = [
  {
    up: migration_20261003_154350_initial.up,
    down: migration_20261003_154350_initial.down,
    name: '20261003_154350_initial',
  },
  {
    up: migration_20261003_155338_ipad.up,
    down: migration_20261003_155338_ipad.down,
    name: '20261003_155338_ipad'
  },
];
