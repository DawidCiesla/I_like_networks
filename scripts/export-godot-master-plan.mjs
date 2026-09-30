import {
  mkdir,
  writeFile,
} from 'node:fs/promises';

import {
  generateCityMasterPlan,
} from '../src/city/planGenerator.js';

const seed =
  Number.parseInt(
    process.argv[2] ?? '284731',
    10,
  );

if (!Number.isFinite(seed)) {
  throw new Error(
    'Seed must be a finite integer.',
  );
}

const plan =
  generateCityMasterPlan(seed);

const payload = {
  schemaVersion: 1,
  source:
    'web-plan-generator-v12',
  seed,
  districts:
    plan.districts,
  roads:
    plan.roads,
  nodes:
    plan.nodes,
  graphEdges:
    plan.graphEdges,
  junctions:
    plan.junctions,
  blocks:
    plan.blocks,
  parcels:
    plan.parcels,
  reservations:
    plan.reservations,
};

await mkdir(
  new URL(
    '../godot/data/',
    import.meta.url,
  ),
  {
    recursive: true,
  },
);

const target =
  new URL(
    `../godot/data/master_plan_${seed}.json`,
    import.meta.url,
  );

await writeFile(
  target,
  `${JSON.stringify(
    payload,
    null,
    2,
  )}\n`,
  'utf8',
);

console.log(
  [
    `Godot master plan exported for seed ${seed}.`,
    `districts=${plan.districts.length}`,
    `roads=${plan.roads.length}`,
    `graphEdges=${plan.graphEdges.length}`,
    `junctions=${plan.junctions.length}`,
    `parcels=${plan.parcels.length}`,
  ].join(' '),
);
