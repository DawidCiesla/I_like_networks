import {
  WORLD,
  getDepotSpurRoute,
  getSegmentRoute,
} from '../render/transportLayout.js';

const DISTRICTS = Object.freeze([
  {
    id: 'oldTown',
    name: 'Old Town',
    lineKey: 'line1',
    stopIndex: 0,
    theme: 'residential',
    roads: [
      [[-125, -118], [-125, 118]],
      [[-125, -118], [105, -118]],
    ],
    parcels: [
      [-92, -72, 'residential'],
      [-28, -82, 'residential'],
      [42, -76, 'residential'],
      [104, -66, 'mixed'],
      [-100, 82, 'residential'],
      [-36, 92, 'residential'],
      [40, 88, 'residential'],
      [108, 76, 'mixed'],
    ],
  },
  {
    id: 'market',
    name: 'Market Square',
    lineKey: 'line1',
    stopIndex: 1,
    theme: 'mixed',
    roads: [
      [[-115, 122], [118, 122]],
      [[118, 122], [118, 34]],
    ],
    parcels: [
      [-72, -148, 'mixed'],
      [2, -154, 'commercial'],
      [92, 166, 'mixed'],
      [148, 72, 'commercial'],
      [152, 154, 'mixed'],
      [74, 198, 'residential'],
    ],
  },
  {
    id: 'park',
    name: 'City Park',
    lineKey: 'line1',
    stopIndex: 2,
    theme: 'park',
    roads: [
      [[-138, 132], [132, 132]],
    ],
    parcels: [
      [-122, 196, 'residential'],
      [-46, 198, 'commercial'],
      [48, 196, 'residential'],
      [118, 190, 'residential'],
    ],
  },
  {
    id: 'university',
    name: 'University',
    lineKey: 'line1',
    stopIndex: 3,
    theme: 'campus',
    roads: [
      [[-132, 126], [126, 126]],
      [[126, 126], [126, 42]],
    ],
    parcels: [
      [-100, -88, 'civic'],
      [-26, -98, 'residential'],
      [56, -90, 'residential'],
      [112, -72, 'civic'],
      [-104, 88, 'residential'],
      [10, 102, 'mixed'],
      [96, 82, 'residential'],
    ],
  },
  {
    id: 'central',
    name: 'Central',
    lineKey: 'line1',
    stopIndex: 4,
    theme: 'central',
    roads: [
      [[-145, 140], [145, 140]],
      [[145, 140], [145, -132]],
      [[-142, -142], [142, -142]],
    ],
    parcels: [
      [-116, -98, 'mixed'],
      [-42, -112, 'commercial'],
      [42, -106, 'mixed'],
      [116, -88, 'commercial'],
      [-112, 94, 'residential'],
      [-34, 108, 'mixed'],
      [48, 104, 'mixed'],
      [122, 90, 'commercial'],
    ],
  },
  {
    id: 'riverside',
    name: 'Riverside',
    lineKey: 'line2',
    stopIndex: 1,
    theme: 'riverside',
    roads: [
      [[-132, 128], [126, 128]],
    ],
    parcels: [
      [-106, -82, 'residential'],
      [-34, -96, 'residential'],
      [64, -84, 'residential'],
      [-104, 86, 'residential'],
      [-30, 98, 'mixed'],
      [72, 88, 'residential'],
    ],
  },
  {
    id: 'museum',
    name: 'Museum',
    lineKey: 'line2',
    stopIndex: 2,
    theme: 'mixed',
    roads: [
      [[-136, 132], [136, 132]],
      [[136, 132], [136, 42]],
    ],
    parcels: [
      [-110, -84, 'mixed'],
      [-34, -100, 'civic'],
      [54, -90, 'mixed'],
      [112, -72, 'commercial'],
      [-104, 90, 'residential'],
      [-24, 106, 'mixed'],
      [64, 92, 'residential'],
    ],
  },
  {
    id: 'harbor',
    name: 'Harbor',
    lineKey: 'line2',
    stopIndex: 3,
    theme: 'industrial',
    roads: [
      [[-150, 132], [148, 132]],
      [[148, 132], [148, -120]],
    ],
    parcels: [
      [-112, -86, 'industrial'],
      [-34, -98, 'industrial'],
      [66, -88, 'industrial'],
      [124, -62, 'industrial'],
      [-106, 92, 'industrial'],
      [-12, 104, 'mixed'],
      [92, 86, 'industrial'],
    ],
  },
]);

function hashString(value) {
  let hash = 2166136261;

  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }

  return hash >>> 0;
}

function unitRandom(seed, key) {
  return (
    hashString(`${seed}:${key}`)
    / 0xffffffff
  );
}

function getStop(definition) {
  return WORLD[
    definition.lineKey + 'Stops'
  ][definition.stopIndex];
}

function roadNodeKey(point) {
  return `${Math.round(point.x * 10)}:${Math.round(point.y * 10)}`;
}

function ensureNode(nodes, nodeByKey, point) {
  const key = roadNodeKey(point);

  if (nodeByKey.has(key)) {
    return nodeByKey.get(key);
  }

  const id = `node-${nodes.length + 1}`;

  nodes.push({
    id,
    x: point.x,
    y: point.y,
  });

  nodeByKey.set(key, id);
  return id;
}

function makeEdge(
  nodes,
  nodeByKey,
  {
    id,
    districtId,
    roadClass,
    points,
    unlock,
    buildOrder = 0,
    source = 'city',
  },
) {
  const first = points[0];
  const last = points[points.length - 1];

  return {
    id,
    districtId,
    class: roadClass,
    source,
    fromNodeId: ensureNode(
      nodes,
      nodeByKey,
      first,
    ),
    toNodeId: ensureNode(
      nodes,
      nodeByKey,
      last,
    ),
    points: points.map(
      (point) => ({ ...point }),
    ),
    unlock,
    buildOrder,
    status: 'planned',
    constructionProgress: 0,
  };
}

function getPrimaryRoadSpecs() {
  const specs = [];

  for (let segment = 0; segment < 4; segment += 1) {
    specs.push({
      id: `arterial-line1-${segment}`,
      districtId: DISTRICTS[segment + 1].id,
      roadClass: 'arterial',
      points:
        getSegmentRoute(
          'line1',
          segment,
          segment + 1,
        ).points,
      unlock: {
        lineKey: 'line1',
        stopCount: segment + 2,
      },
      buildOrder: -10,
      source: 'transport-corridor',
    });
  }

  for (let segment = 0; segment < 3; segment += 1) {
    specs.push({
      id: `arterial-line2-${segment}`,
      districtId: DISTRICTS[segment + 5].id,
      roadClass: 'arterial',
      points:
        getSegmentRoute(
          'line2',
          segment,
          segment + 1,
        ).points,
      unlock: {
        lineKey: 'line2',
        stopCount: segment + 2,
      },
      buildOrder: -10,
      source: 'transport-corridor',
    });
  }

  specs.push({
    id: 'depot-access',
    districtId: 'park',
    roadClass: 'service',
    points:
      getDepotSpurRoute().points,
    unlock: {
      lineKey: 'line1',
      stopCount: 3,
      requiresDepot: true,
    },
    buildOrder: 50,
    source: 'depot-access',
  });

  return specs;
}

function parcelFootprint(zone, density) {
  if (zone === 'industrial') {
    return { w: 54, h: 36 };
  }

  if (
    zone === 'commercial'
    && density >= 2
  ) {
    return { w: 42, h: 34 };
  }

  if (
    zone === 'mixed'
    || zone === 'civic'
  ) {
    return { w: 40, h: 32 };
  }

  return { w: 32, h: 28 };
}


function distancePointToSegment(
  point,
  a,
  b,
) {
  const dx = b.x - a.x;
  const dy = b.y - a.y;
  const lengthSquared =
    dx * dx + dy * dy;

  if (lengthSquared <= 1e-9) {
    return Math.hypot(
      point.x - a.x,
      point.y - a.y,
    );
  }

  const t = Math.min(
    1,
    Math.max(
      0,
      (
        (point.x - a.x) * dx
        + (point.y - a.y) * dy
      ) / lengthSquared,
    ),
  );

  return Math.hypot(
    point.x - (a.x + dx * t),
    point.y - (a.y + dy * t),
  );
}

function distancePointToRoad(
  point,
  road,
) {
  let minimum =
    Number.POSITIVE_INFINITY;

  for (
    let index = 0;
    index < road.points.length - 1;
    index += 1
  ) {
    minimum = Math.min(
      minimum,
      distancePointToSegment(
        point,
        road.points[index],
        road.points[index + 1],
      ),
    );
  }

  return minimum;
}

function boxesOverlap(
  a,
  b,
  margin = 8,
) {
  return !(
    a.x + a.w + margin < b.x
    || b.x + b.w + margin < a.x
    || a.y + a.h + margin < b.y
    || b.y + b.h + margin < a.y
  );
}

function validateParcels(
  parcels,
  roads,
) {
  const stops = [
    ...WORLD.line1Stops,
    ...WORLD.line2Stops.slice(1),
  ];

  const accepted = [];

  for (const parcel of parcels) {
    const footprintRadius =
      Math.max(
        Math.max(
          12,
          parcel.w - 12,
        ),
        Math.max(
          12,
          parcel.h - 12,
        ),
      ) / 2;

    const roadCollision =
      roads.some(
        (road) =>
          distancePointToRoad(
            parcel,
            road,
          )
          < footprintRadius
            + (
              road.class === 'arterial'
                ? 21
                : 8
            ),
      );

    if (roadCollision) {
      continue;
    }

    const stopCollision =
      stops.some(
        (stop) =>
          Math.hypot(
            parcel.x - stop.x,
            parcel.y - stop.y,
          ) < 48,
      );

    if (stopCollision) {
      continue;
    }

    const depotCollision =
      Math.abs(
        parcel.x - WORLD.depot.x,
      ) < 86
      && Math.abs(
        parcel.y - WORLD.depot.y,
      ) < 68;

    if (depotCollision) {
      continue;
    }

    const box = {
      x:
        parcel.x - parcel.w / 2,
      y:
        parcel.y - parcel.h / 2,
      w: parcel.w,
      h: parcel.h,
    };

    const parcelCollision =
      accepted.some(
        (candidate) =>
          boxesOverlap(
            box,
            {
              x:
                candidate.x
                - candidate.w / 2,
              y:
                candidate.y
                - candidate.h / 2,
              w: candidate.w,
              h: candidate.h,
            },
          ),
      );

    if (parcelCollision) {
      continue;
    }

    const frontageRoad =
      roads
        .map(
          (road) => ({
            id: road.id,
            distance:
              distancePointToRoad(
                parcel,
                road,
              ),
          }),
        )
        .sort(
          (a, b) =>
            a.distance - b.distance,
        )[0];

    accepted.push({
      ...parcel,
      frontageRoadId:
        frontageRoad?.id ?? null,
    });
  }

  return accepted;
}

function districtDensity(theme) {
  if (theme === 'central') return 3;
  if (theme === 'campus') return 2;
  if (theme === 'mixed') return 2;
  if (theme === 'industrial') return 2;
  if (theme === 'riverside') return 1;
  if (theme === 'park') return 1;
  return 1;
}

export function generateCityMasterPlan(
  seed = 284731,
) {
  const nodes = [];
  const nodeByKey = new Map();
  const roads = [];
  const blocks = [];
  const parcels = [];
  const districts = [];

  for (
    const spec
    of getPrimaryRoadSpecs()
  ) {
    roads.push(
      makeEdge(
        nodes,
        nodeByKey,
        spec,
      ),
    );
  }

  for (
    const definition
    of DISTRICTS
  ) {
    const stop =
      getStop(definition);

    const roadIds = [];

    definition.roads.forEach(
      (roadPoints, index) => {
        const points =
          roadPoints.map(
            ([dx, dy]) => ({
              x: stop.x + dx,
              y: stop.y + dy,
            }),
          );

        const id =
          `local-${definition.id}-${index + 1}`;

        roadIds.push(id);

        roads.push(
          makeEdge(
            nodes,
            nodeByKey,
            {
              id,
              districtId:
                definition.id,
              roadClass:
                index === 0
                  ? 'local'
                  : 'local',
              points,
              unlock: {
                districtId:
                  definition.id,
              },
              buildOrder: index,
            },
          ),
        );
      },
    );

    const density =
      districtDensity(
        definition.theme,
      );

    const districtParcelIds = [];

    definition.parcels.forEach(
      ([dx, dy, zone], index) => {
        const id =
          `parcel-${definition.id}-${index + 1}`;

        const jitterX =
          Math.round(
            (unitRandom(seed, id + ':x') - 0.5)
            * 8,
          );

        const jitterY =
          Math.round(
            (unitRandom(seed, id + ':y') - 0.5)
            * 8,
          );

        const parcelDensity =
          Math.max(
            1,
            density
              + (
                unitRandom(
                  seed,
                  id + ':density',
                ) > 0.76
                  ? 1
                  : 0
              ),
          );

        const footprint =
          parcelFootprint(
            zone,
            parcelDensity,
          );

        districtParcelIds.push(id);

        parcels.push({
          id,
          districtId:
            definition.id,
          blockId: null,
          x:
            stop.x + dx + jitterX,
          y:
            stop.y + dy + jitterY,
          w: footprint.w + 12,
          h: footprint.h + 12,
          frontage:
            18
            + Math.round(
              unitRandom(
                seed,
                id + ':frontage',
              ) * 18,
            ),
          setback:
            5
            + Math.round(
              unitRandom(
                seed,
                id + ':setback',
              ) * 5,
            ),
          zone,
          density:
            parcelDensity,
          developmentOrder:
            unitRandom(
              seed,
              id + ':order',
            ),
          status: 'vacant',
          buildingId: null,
          reservedAt: null,
        });
      },
    );

    const blockCount =
      Math.max(
        1,
        Math.min(
          2,
          Math.ceil(
            districtParcelIds.length / 4,
          ),
        ),
      );

    const blockIds = [];

    for (
      let blockIndex = 0;
      blockIndex < blockCount;
      blockIndex += 1
    ) {
      const id =
        `block-${definition.id}-${blockIndex + 1}`;

      blockIds.push(id);

      const blockParcelIds =
        districtParcelIds.filter(
          (_, index) =>
            index % blockCount
            === blockIndex,
        );

      blocks.push({
        id,
        districtId:
          definition.id,
        parcelIds:
          blockParcelIds,
        status: 'planned',
      });

      for (
        const parcelId
        of blockParcelIds
      ) {
        const parcel =
          parcels.find(
            (candidate) =>
              candidate.id
              === parcelId,
          );

        parcel.blockId = id;
      }
    }

    districts.push({
      id: definition.id,
      name: definition.name,
      lineKey:
        definition.lineKey,
      stopIndex:
        definition.stopIndex,
      theme:
        definition.theme,
      anchor: {
        x: stop.x,
        y: stop.y,
      },
      roadIds,
      blockIds,
      parcelIds:
        districtParcelIds,
      status: 'locked',
      activatedAt: null,
      developmentLevel: 0,
    });
  }

  const validParcels =
    validateParcels(
      parcels,
      roads,
    );

  const validParcelIds =
    new Set(
      validParcels.map(
        (parcel) => parcel.id,
      ),
    );

  const validBlocks =
    blocks
      .map(
        (block) => ({
          ...block,
          parcelIds:
            block.parcelIds.filter(
              (parcelId) =>
                validParcelIds.has(
                  parcelId,
                ),
            ),
        }),
      )
      .filter(
        (block) =>
          block.parcelIds.length > 0,
      );

  const validBlockIds =
    new Set(
      validBlocks.map(
        (block) => block.id,
      ),
    );

  const validDistricts =
    districts.map(
      (district) => ({
        ...district,
        parcelIds:
          district.parcelIds.filter(
            (parcelId) =>
              validParcelIds.has(
                parcelId,
              ),
          ),
        blockIds:
          district.blockIds.filter(
            (blockId) =>
              validBlockIds.has(
                blockId,
              ),
          ),
      }),
    );

  return {
    seed,
    nodes,
    roads,
    districts:
      validDistricts,
    blocks:
      validBlocks,
    parcels:
      validParcels,
  };
}

export function getDistrictDefinitions() {
  return DISTRICTS.map(
    (district) => ({
      id: district.id,
      name: district.name,
      lineKey:
        district.lineKey,
      stopIndex:
        district.stopIndex,
      theme:
        district.theme,
    }),
  );
}
