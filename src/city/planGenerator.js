import {
  WORLD,
  getDepotSpurRoute,
  getSegmentRoute,
} from '../render/transportLayout.js';

import {
  ROAD_TOPOLOGY,
  closestPointOnRoad,
  compileRoadGraph,
  distance,
  findNearestAttachment,
  normalize,
  polylineLength,
  roadHalfWidth,
  snapCandidateStartToRoad,
  trimRoadToFirstIntersection,
  validateRoadCandidate,
} from './roadTopology.js';

const DISTRICT_SPECS = Object.freeze([
  {
    id: 'oldTown',
    name: 'Old Town',
    lineKey: 'line1',
    stopIndex: 0,
    theme: 'residential',
    parentRoadId: 'arterial-oldTown-existing',
    branchSide: 1,
    depth: 250,
    halfWidth: 210,
    crossRoadCount: 2,
  },
  {
    id: 'market',
    name: 'Market Square',
    lineKey: 'line1',
    stopIndex: 1,
    theme: 'mixed',
    parentRoadId: 'arterial-line1-0',
    branchSide: -1,
    depth: 280,
    halfWidth: 235,
    crossRoadCount: 2,
  },
  {
    id: 'park',
    name: 'City Park',
    lineKey: 'line1',
    stopIndex: 2,
    theme: 'park',
    parentRoadId: 'arterial-line1-1',
    branchSide: 1,
    depth: 270,
    halfWidth: 215,
    crossRoadCount: 2,
  },
  {
    id: 'university',
    name: 'University',
    lineKey: 'line1',
    stopIndex: 3,
    theme: 'campus',
    parentRoadId: 'arterial-line1-2',
    branchSide: -1,
    depth: 310,
    halfWidth: 245,
    crossRoadCount: 2,
  },
  {
    id: 'central',
    name: 'Central',
    lineKey: 'line1',
    stopIndex: 4,
    theme: 'central',
    parentRoadId: 'arterial-line1-3',
    branchSide: 1,
    depth: 350,
    halfWidth: 285,
    crossRoadCount: 3,
  },
  {
    id: 'riverside',
    name: 'Riverside',
    lineKey: 'line2',
    stopIndex: 1,
    theme: 'riverside',
    parentRoadId: 'arterial-line2-0',
    branchSide: 1,
    depth: 280,
    halfWidth: 225,
    crossRoadCount: 2,
  },
  {
    id: 'museum',
    name: 'Museum',
    lineKey: 'line2',
    stopIndex: 2,
    theme: 'mixed',
    parentRoadId: 'arterial-line2-1',
    branchSide: -1,
    depth: 300,
    halfWidth: 245,
    crossRoadCount: 2,
  },
  {
    id: 'harbor',
    name: 'Harbor',
    lineKey: 'line2',
    stopIndex: 3,
    theme: 'industrial',
    parentRoadId: 'arterial-line2-2',
    branchSide: 1,
    depth: 350,
    halfWidth: 300,
    crossRoadCount: 2,
  },
]);

function hashString(value) {
  let hash = 2166136261;

  for (
    let index = 0;
    index < value.length;
    index += 1
  ) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(
      hash,
      16777619,
    );
  }

  return hash >>> 0;
}

function unitRandom(seed, key) {
  return (
    hashString(
      `${seed}:${key}`,
    )
    / 0xffffffff
  );
}

function getStop(spec) {
  return WORLD[
    spec.lineKey + 'Stops'
  ][spec.stopIndex];
}

function add(
  point,
  vector,
  amount,
) {
  return {
    x:
      point.x
      + vector.x * amount,
    y:
      point.y
      + vector.y * amount,
  };
}

function getPrimaryRoadSpecs() {
  const specs = [];
  const oldTown =
    WORLD.line1Stops[0];

  specs.push({
    id:
      'arterial-oldTown-existing',
    districtId: 'oldTown',
    class: 'arterial',
    points: [
      {
        x: oldTown.x - 380,
        y: oldTown.y,
      },
      {
        x: oldTown.x,
        y: oldTown.y,
      },
    ],
    unlock: null,
    buildOrder: -20,
    source: 'existing-arterial',
    parentRoadIds: [],
    status: 'planned',
    constructionProgress: 0,
  });

  for (
    let segment = 0;
    segment < 4;
    segment += 1
  ) {
    specs.push({
      id:
        `arterial-line1-${segment}`,
      districtId:
        DISTRICT_SPECS[
          segment + 1
        ].id,
      class: 'arterial',
      points:
        getSegmentRoute(
          'line1',
          segment,
          segment + 1,
        ).points.map(
          (point) => ({
            ...point,
          }),
        ),
      unlock: {
        lineKey: 'line1',
        stopCount:
          segment + 2,
      },
      buildOrder: -10,
      source:
        'transport-corridor',
      parentRoadIds: [
        segment === 0
          ? 'arterial-oldTown-existing'
          : `arterial-line1-${segment - 1}`,
      ],
      status: 'planned',
      constructionProgress: 0,
    });
  }

  for (
    let segment = 0;
    segment < 3;
    segment += 1
  ) {
    specs.push({
      id:
        `arterial-line2-${segment}`,
      districtId:
        DISTRICT_SPECS[
          segment + 5
        ].id,
      class: 'arterial',
      points:
        getSegmentRoute(
          'line2',
          segment,
          segment + 1,
        ).points.map(
          (point) => ({
            ...point,
          }),
        ),
      unlock: {
        lineKey: 'line2',
        stopCount:
          segment + 2,
      },
      buildOrder: -10,
      source:
        'transport-corridor',
      parentRoadIds: [
        segment === 0
          ? 'arterial-line1-1'
          : `arterial-line2-${segment - 1}`,
      ],
      status: 'planned',
      constructionProgress: 0,
    });
  }

  specs.push({
    id: 'depot-access',
    districtId: 'park',
    class: 'service',
    points:
      getDepotSpurRoute()
        .points
        .map(
          (point) => ({
            ...point,
          }),
        ),
    unlock: {
      lineKey: 'line1',
      stopCount: 3,
      requiresDepot: true,
    },
    buildOrder: 50,
    source: 'depot-access',
    parentRoadIds: [
      'arterial-line1-1',
    ],
    status: 'planned',
    constructionProgress: 0,
  });

  return specs;
}

function createReservations() {
  const parkStop =
    WORLD.line1Stops[2];

  return [
    {
      id:
        'reservation-bus-depot',
      type: 'facility',
      facilityType:
        'bus-depot',
      x: WORLD.depot.x,
      y: WORLD.depot.y,
      w: 250,
      h: 190,
      padding: 34,
      status: 'reserved',
    },
    {
      id:
        'reservation-city-park',
      type: 'open-space',
      facilityType: 'park',
      x:
        parkStop.x - 225,
      y:
        parkStop.y - 245,
      w: 285,
      h: 220,
      padding: 24,
      status: 'reserved',
    },
  ];
}

function tangentOnRoadAtPoint(
  road,
  point,
) {
  const closest =
    closestPointOnRoad(
      point,
      road,
    );

  if (!closest) {
    return {
      x: 1,
      y: 0,
    };
  }

  const a =
    road.points[
      closest.segmentIndex
    ];

  const b =
    road.points[
      closest.segmentIndex + 1
    ];

  return normalize(
    b.x - a.x,
    b.y - a.y,
  );
}

function endpointNearRoad(
  point,
  road,
  tolerance = 2.5,
) {
  const closest =
    closestPointOnRoad(
      point,
      road,
    );

  return Boolean(
    closest
    && closest.distance
      <= tolerance,
  );
}

function addRoadCandidate(
  roads,
  candidate,
  reservations,
  {
    ignoreReservationIds = [],
  } = {},
) {
  const parentRoadIds =
    candidate.parentRoadIds
      ?? [];

  const snapped =
    snapCandidateStartToRoad(
      candidate,
      roads,
      parentRoadIds,
    );

  if (!snapped.ok) {
    return {
      ok: false,
      reason: snapped.reason,
    };
  }

  let road =
    snapped.road;

  const trimmed =
    trimRoadToFirstIntersection(
      road,
      roads,
      {
        ignoreRoadIds:
          parentRoadIds,
      },
    );

  road = trimmed.road;

  const connectionRoadIds = [];

  if (
    trimmed.connectionRoadId
    && !parentRoadIds.includes(
      trimmed.connectionRoadId,
    )
  ) {
    connectionRoadIds.push(
      trimmed.connectionRoadId,
    );
  }

  const end =
    road.points.at(-1);

  const endAttachment =
    findNearestAttachment(
      end,
      roads,
      {
        maxDistance:
          ROAD_TOPOLOGY
            .roadSnapRadius,
      },
    );

  if (
    endAttachment
    && !parentRoadIds.includes(
      endAttachment.road.id,
    )
    && !connectionRoadIds.includes(
      endAttachment.road.id,
    )
    && polylineLength(
      road.points,
    )
      >= ROAD_TOPOLOGY
        .minimumJunctionSpacing
  ) {
    road = {
      ...road,
      points: [
        ...road.points.slice(
          0,
          -1,
        ),
        {
          ...endAttachment.point,
        },
      ],
    };

    connectionRoadIds.push(
      endAttachment.road.id,
    );
  }

  if (
    polylineLength(
      road.points,
    )
    < ROAD_TOPOLOGY
      .minimumJunctionSpacing
  ) {
    return {
      ok: false,
      reason: 'too-short-after-snap',
    };
  }

  const validation =
    validateRoadCandidate(
      road,
      roads,
      {
        allowedTouchRoadIds: [
          ...parentRoadIds,
          ...connectionRoadIds,
        ],
        reservations,
        ignoreReservationIds,
      },
    );

  if (!validation.ok) {
    return validation;
  }

  const finalRoad = {
    ...road,
    parentRoadIds:
      [...parentRoadIds],
    connectionRoadIds,
    status: 'planned',
    constructionProgress: 0,
  };

  roads.push(finalRoad);

  return {
    ok: true,
    road: finalRoad,
  };
}

function makeCollectorCandidate(
  spec,
  parentRoad,
  side,
) {
  const stop =
    getStop(spec);

  const attachment =
    closestPointOnRoad(
      stop,
      parentRoad,
    );

  const start =
    attachment?.point
      ?? {
        x: stop.x,
        y: stop.y,
      };

  const tangent =
    tangentOnRoadAtPoint(
      parentRoad,
      start,
    );

  const normal = {
    x:
      -tangent.y * side,
    y:
      tangent.x * side,
  };

  const end =
    add(
      start,
      normal,
      spec.depth,
    );

  return {
    road: {
      id:
        `collector-${spec.id}`,
      districtId: spec.id,
      class: 'collector',
      source: 'city',
      buildOrder: 0,
      parentRoadIds: [
        parentRoad.id,
      ],
      points: [
        { ...start },
        {
          x:
            start.x
            + normal.x
              * spec.depth * 0.52,
          y:
            start.y
            + normal.y
              * spec.depth * 0.52,
        },
        end,
      ],
      unlock: {
        districtId: spec.id,
      },
    },
    tangent,
    normal,
  };
}

function pointAlongPolyline(
  road,
  fraction,
) {
  const target =
    polylineLength(
      road.points,
    )
    * fraction;

  let travelled = 0;

  for (
    let index = 0;
    index < road.points.length - 1;
    index += 1
  ) {
    const a =
      road.points[index];

    const b =
      road.points[index + 1];

    const length =
      distance(a, b);

    if (
      travelled + length
      >= target
    ) {
      const local =
        length <= 1e-9
          ? 0
          : (
            target - travelled
          ) / length;

      return {
        x:
          a.x
          + (b.x - a.x)
            * local,
        y:
          a.y
          + (b.y - a.y)
            * local,
      };
    }

    travelled += length;
  }

  return {
    ...road.points.at(-1),
  };
}

function makeCrossCandidate(
  spec,
  collector,
  tangent,
  fraction,
  direction,
  index,
) {
  const start =
    pointAlongPolyline(
      collector,
      fraction,
    );

  const variation =
    0.9
    + (
      (index % 2) * 0.08
    );

  const end =
    add(
      start,
      tangent,
      direction
        * spec.halfWidth
        * variation,
    );

  return {
    id:
      `local-${spec.id}-`
      + `cross-${index}-`
      + (
        direction < 0
          ? 'left'
          : 'right'
      ),
    districtId: spec.id,
    class: 'local',
    source: 'city',
    buildOrder:
      1 + index,
    parentRoadIds: [
      collector.id,
    ],
    points: [
      { ...start },
      end,
    ],
    unlock: {
      districtId: spec.id,
    },
  };
}

function roadEndpoint(
  road,
) {
  return {
    ...road.points.at(-1),
  };
}

function makeSideCandidate(
  spec,
  firstRoad,
  secondRoad,
  sideLabel,
  buildOrder,
) {
  return {
    id:
      `local-${spec.id}-side-`
      + sideLabel
      + '-'
      + buildOrder,
    districtId: spec.id,
    class: 'local',
    source: 'city',
    buildOrder,
    parentRoadIds: [
      firstRoad.id,
      secondRoad.id,
    ],
    points: [
      roadEndpoint(firstRoad),
      roadEndpoint(secondRoad),
    ],
    unlock: {
      districtId: spec.id,
    },
  };
}

function generateDistrictRoads(
  roads,
  reservations,
  spec,
) {
  const parentRoad =
    roads.find(
      (road) =>
        road.id
        === spec.parentRoadId,
    );

  if (!parentRoad) {
    return [];
  }

  const preferredSides = [
    spec.branchSide,
    -spec.branchSide,
  ];

  let collector = null;
  let tangent = null;

  for (
    const side
    of preferredSides
  ) {
    const proposal =
      makeCollectorCandidate(
        spec,
        parentRoad,
        side,
      );

    const added =
      addRoadCandidate(
        roads,
        proposal.road,
        reservations,
      );

    if (added.ok) {
      collector =
        added.road;

      tangent =
        proposal.tangent;

      break;
    }
  }

  if (!collector) {
    return [];
  }

  const districtRoads = [
    collector,
  ];

  const fractions =
    spec.crossRoadCount >= 3
      ? [0.34, 0.62, 0.9]
      : [0.46, 0.86];

  const leftRoads = [];
  const rightRoads = [];

  fractions.forEach(
    (fraction, index) => {
      const left =
        addRoadCandidate(
          roads,
          makeCrossCandidate(
            spec,
            collector,
            tangent,
            fraction,
            -1,
            index,
          ),
          reservations,
        );

      if (left.ok) {
        leftRoads.push(
          left.road,
        );

        districtRoads.push(
          left.road,
        );
      }

      const right =
        addRoadCandidate(
          roads,
          makeCrossCandidate(
            spec,
            collector,
            tangent,
            fraction,
            1,
            index,
          ),
          reservations,
        );

      if (right.ok) {
        rightRoads.push(
          right.road,
        );

        districtRoads.push(
          right.road,
        );
      }
    },
  );

  const connectSides = (
    sideRoads,
    label,
  ) => {
    for (
      let index = 0;
      index < sideRoads.length - 1;
      index += 1
    ) {
      const candidate =
        makeSideCandidate(
          spec,
          sideRoads[index],
          sideRoads[index + 1],
          label,
          10 + index,
        );

      const added =
        addRoadCandidate(
          roads,
          candidate,
          reservations,
        );

      if (added.ok) {
        districtRoads.push(
          added.road,
        );
      }
    }
  };

  connectSides(
    leftRoads,
    'left',
  );

  connectSides(
    rightRoads,
    'right',
  );

  return districtRoads;
}

function parcelFootprint(
  zone,
  density,
) {
  if (zone === 'industrial') {
    return {
      w: 66,
      h: 50,
    };
  }

  if (zone === 'civic') {
    return {
      w: 60,
      h: 48,
    };
  }

  if (
    zone === 'commercial'
    || zone === 'mixed'
  ) {
    return {
      w:
        density >= 3
          ? 54
          : 46,
      h:
        density >= 3
          ? 46
          : 39,
    };
  }

  return {
    w:
      density >= 2
        ? 44
        : 36,
    h:
      density >= 2
        ? 39
        : 31,
  };
}

function densityForTheme(
  theme,
) {
  if (theme === 'central') return 3;
  if (theme === 'campus') return 2;
  if (theme === 'mixed') return 2;
  if (theme === 'industrial') return 2;
  return 1;
}

function zoneFor(
  theme,
  roadIndex,
  sampleIndex,
  side,
) {
  const selector =
    (
      roadIndex * 5
      + sampleIndex * 3
      + (side > 0 ? 1 : 0)
    ) % 7;

  if (theme === 'industrial') {
    return (
      selector === 0
        ? 'mixed'
        : 'industrial'
    );
  }

  if (theme === 'campus') {
    return (
      selector < 2
        ? 'civic'
        : selector === 2
          ? 'mixed'
          : 'residential'
    );
  }

  if (theme === 'central') {
    return (
      selector < 3
        ? 'commercial'
        : 'mixed'
    );
  }

  if (theme === 'mixed') {
    return (
      selector < 2
        ? 'commercial'
        : selector < 5
          ? 'mixed'
          : 'residential'
    );
  }

  if (theme === 'park') {
    return (
      selector === 0
        ? 'commercial'
        : 'residential'
    );
  }

  if (theme === 'riverside') {
    return (
      selector === 0
        ? 'mixed'
        : 'residential'
    );
  }

  return (
    selector === 0
      ? 'mixed'
      : 'residential'
  );
}

function roadDirectionAtDistance(
  road,
  target,
) {
  let travelled = 0;

  for (
    let index = 0;
    index < road.points.length - 1;
    index += 1
  ) {
    const a =
      road.points[index];

    const b =
      road.points[index + 1];

    const length =
      distance(a, b);

    if (
      travelled + length
      >= target
    ) {
      const local =
        length <= 1e-9
          ? 0
          : (
            target - travelled
          ) / length;

      const tangent =
        normalize(
          b.x - a.x,
          b.y - a.y,
        );

      return {
        point: {
          x:
            a.x
            + (b.x - a.x)
              * local,
          y:
            a.y
            + (b.y - a.y)
              * local,
        },
        tangent,
      };
    }

    travelled += length;
  }

  const last =
    road.points.at(-1);

  const previous =
    road.points.at(-2)
    ?? {
      x: last.x - 1,
      y: last.y,
    };

  return {
    point: {
      ...last,
    },
    tangent:
      normalize(
        last.x - previous.x,
        last.y - previous.y,
      ),
  };
}

function rectanglesOverlap(
  first,
  second,
  margin = 0,
) {
  return !(
    first.x + first.w + margin
      < second.x
    || second.x + second.w + margin
      < first.x
    || first.y + first.h + margin
      < second.y
    || second.y + second.h + margin
      < first.y
  );
}

function reservationRect(
  reservation,
) {
  const padding =
    reservation.padding
    ?? 0;

  return {
    x:
      reservation.x
      - reservation.w / 2
      - padding,
    y:
      reservation.y
      - reservation.h / 2
      - padding,
    w:
      reservation.w
      + padding * 2,
    h:
      reservation.h
      + padding * 2,
  };
}

function parcelRect(parcel) {
  return {
    x:
      parcel.x
      - parcel.w / 2,
    y:
      parcel.y
      - parcel.h / 2,
    w: parcel.w,
    h: parcel.h,
  };
}

function createParcelCandidates(
  seed,
  spec,
  districtRoads,
) {
  const density =
    densityForTheme(
      spec.theme,
    );

  const candidates = [];

  districtRoads.forEach(
    (road, roadIndex) => {
      const length =
        polylineLength(
          road.points,
        );

      const spacing =
        spec.theme === 'central'
          ? 76
          : spec.theme === 'industrial'
            ? 98
            : 86;

      const start =
        Math.min(
          58,
          length * 0.32,
        );

      const end =
        Math.max(
          start,
          length - 42,
        );

      let sampleIndex = 0;

      for (
        let along = start;
        along <= end;
        along += spacing
      ) {
        const sample =
          roadDirectionAtDistance(
            road,
            along,
          );

        for (
          const side
          of [-1, 1]
        ) {
          const key =
            `${spec.id}:`
            + `${road.id}:`
            + `${sampleIndex}:`
            + side;

          const zone =
            zoneFor(
              spec.theme,
              roadIndex,
              sampleIndex,
              side,
            );

          const localDensity =
            Math.min(
              4,
              density
              + (
                unitRandom(
                  seed,
                  key + ':density',
                ) > 0.8
                  ? 1
                  : 0
              ),
            );

          const footprint =
            parcelFootprint(
              zone,
              localDensity,
            );

          const normal = {
            x:
              -sample.tangent.y
              * side,
            y:
              sample.tangent.x
              * side,
          };

          const roadOffset =
            roadHalfWidth(
              road.class,
            )
            + 13
            + footprint.h / 2;

          const jitterAlong =
            (
              unitRandom(
                seed,
                key + ':along',
              ) - 0.5
            ) * 10;

          const jitterAway =
            (
              unitRandom(
                seed,
                key + ':away',
              ) - 0.5
            ) * 6;

          candidates.push({
            id:
              `parcel-${spec.id}-`
              + `${candidates.length + 1}`,
            districtId:
              spec.id,
            blockId: null,
            x:
              sample.point.x
              + sample.tangent.x
                * jitterAlong
              + normal.x
                * (
                  roadOffset
                  + jitterAway
                ),
            y:
              sample.point.y
              + sample.tangent.y
                * jitterAlong
              + normal.y
                * (
                  roadOffset
                  + jitterAway
                ),
            w:
              footprint.w + 12,
            h:
              footprint.h + 12,
            frontage:
              footprint.w,
            setback:
              6
              + Math.round(
                unitRandom(
                  seed,
                  key + ':setback',
                ) * 6,
              ),
            zone,
            density:
              localDensity,
            developmentOrder:
              unitRandom(
                seed,
                key + ':order',
              ),
            status: 'vacant',
            buildingId: null,
            reservedAt: null,
            frontageRoadId:
              road.id,
            frontageSide:
              side,
          });
        }

        sampleIndex += 1;
      }
    },
  );

  return candidates;
}

function validateParcels(
  candidates,
  roads,
  reservations,
  roadGraph,
) {
  const stops = [
    ...WORLD.line1Stops,
    ...WORLD.line2Stops.slice(1),
  ];

  const accepted = [];

  for (
    const parcel
    of candidates
  ) {
    const box =
      parcelRect(
        parcel,
      );

    const reservationConflict =
      reservations.some(
        (reservation) =>
          rectanglesOverlap(
            box,
            reservationRect(
              reservation,
            ),
          ),
      );

    if (reservationConflict) {
      continue;
    }

    const stopConflict =
      stops.some(
        (stop) =>
          distance(
            parcel,
            stop,
          ) < 72,
      );

    if (stopConflict) {
      continue;
    }

    const junctionConflict =
      roadGraph.junctions.some(
        (junction) =>
          distance(
            parcel,
            junction,
          ) < 48,
      );

    if (junctionConflict) {
      continue;
    }

    let roadConflict = false;

    for (
      const road
      of roads
    ) {
      if (
        road.id
        === parcel.frontageRoadId
      ) {
        continue;
      }

      const closest =
        closestPointOnRoad(
          parcel,
          road,
        );

      if (!closest) {
        continue;
      }

      const required =
        Math.max(
          parcel.w,
          parcel.h,
        ) / 2
        + roadHalfWidth(
          road.class,
        )
        + 10;

      if (
        closest.distance
        < required
      ) {
        roadConflict = true;
        break;
      }
    }

    if (roadConflict) {
      continue;
    }

    const parcelConflict =
      accepted.some(
        (candidate) =>
          rectanglesOverlap(
            box,
            parcelRect(
              candidate,
            ),
            10,
          ),
      );

    if (parcelConflict) {
      continue;
    }

    accepted.push(
      parcel,
    );
  }

  return accepted;
}

function makeBlocks(
  parcels,
  districts,
) {
  const blocks = [];

  for (
    const district
    of districts
  ) {
    const districtParcels =
      parcels.filter(
        (parcel) =>
          parcel.districtId
          === district.id,
      );

    const groups =
      new Map();

    for (
      const parcel
      of districtParcels
    ) {
      const key =
        `${parcel.frontageRoadId}:`
        + parcel.frontageSide;

      if (!groups.has(key)) {
        groups.set(
          key,
          [],
        );
      }

      groups.get(key).push(
        parcel,
      );
    }

    district.blockIds = [];
    district.parcelIds =
      districtParcels.map(
        (parcel) =>
          parcel.id,
      );

    let index = 1;

    for (
      const group
      of groups.values()
    ) {
      const id =
        `block-${district.id}-`
        + index;

      const parcelIds =
        group.map(
          (parcel) =>
            parcel.id,
        );

      district.blockIds.push(
        id,
      );

      blocks.push({
        id,
        districtId:
          district.id,
        parcelIds,
        status: 'planned',
      });

      for (
        const parcel
        of group
      ) {
        parcel.blockId = id;
      }

      index += 1;
    }
  }

  return blocks;
}

function createDistrictRecord(
  spec,
  roadIds,
) {
  const stop =
    getStop(spec);

  return {
    id: spec.id,
    name: spec.name,
    lineKey:
      spec.lineKey,
    stopIndex:
      spec.stopIndex,
    theme:
      spec.theme,
    anchor: {
      x: stop.x,
      y: stop.y,
    },
    parentRoadId:
      spec.parentRoadId,
    roadIds,
    blockIds: [],
    parcelIds: [],
    status: 'locked',
    activatedAt: null,
    developmentLevel: 0,
  };
}

export function generateCityMasterPlan(
  seed = 284731,
) {
  const reservations =
    createReservations();

  const roads =
    getPrimaryRoadSpecs();

  const districts = [];
  const parcelCandidates = [];

  for (
    const spec
    of DISTRICT_SPECS
  ) {
    const districtRoads =
      generateDistrictRoads(
        roads,
        reservations,
        spec,
      );

    districts.push(
      createDistrictRecord(
        spec,
        districtRoads.map(
          (road) =>
            road.id,
        ),
      ),
    );

    parcelCandidates.push(
      ...createParcelCandidates(
        seed,
        spec,
        districtRoads,
      ),
    );
  }

  const roadGraph =
    compileRoadGraph(
      roads,
    );

  const parcels =
    validateParcels(
      parcelCandidates,
      roads,
      reservations,
      roadGraph,
    );

  const blocks =
    makeBlocks(
      parcels,
      districts,
    );

  return {
    seed,
    nodes:
      roadGraph.nodes,
    graphEdges:
      roadGraph.edges,
    junctions:
      roadGraph.junctions,
    roads,
    districts,
    blocks,
    parcels,
    reservations,
  };
}

export function getDistrictDefinitions() {
  return DISTRICT_SPECS.map(
    (district) => ({
      id: district.id,
      name: district.name,
      lineKey:
        district.lineKey,
      stopIndex:
        district.stopIndex,
      theme:
        district.theme,
      parentRoadId:
        district.parentRoadId,
    }),
  );
}
