export const ROAD_TOPOLOGY = Object.freeze({
  nodeSnapRadius: 28,
  roadSnapRadius: 32,
  intersectionTolerance: 1.5,
  minimumJunctionSpacing: 68,
  minimumIntersectionAngleDeg: 32,
  parallelAngleDeg: 18,
  parallelClearance: 18,
});

const EPSILON = 1e-7;

export function distance(a, b) {
  return Math.hypot(
    b.x - a.x,
    b.y - a.y,
  );
}

export function normalize(dx, dy) {
  const length = Math.hypot(dx, dy);

  if (length <= EPSILON) {
    return { x: 1, y: 0 };
  }

  return {
    x: dx / length,
    y: dy / length,
  };
}

export function roadHalfWidth(roadClass) {
  if (roadClass === 'arterial') return 21;
  if (roadClass === 'collector') return 15;
  if (roadClass === 'service') return 10;
  return 12;
}

export function polylineLength(points) {
  let total = 0;

  for (
    let index = 0;
    index < points.length - 1;
    index += 1
  ) {
    total += distance(
      points[index],
      points[index + 1],
    );
  }

  return total;
}

export function closestPointOnSegment(
  point,
  a,
  b,
) {
  const dx = b.x - a.x;
  const dy = b.y - a.y;
  const lengthSquared =
    dx * dx + dy * dy;

  if (lengthSquared <= EPSILON) {
    return {
      point: { ...a },
      t: 0,
      distance: distance(
        point,
        a,
      ),
    };
  }

  const t = Math.max(
    0,
    Math.min(
      1,
      (
        (point.x - a.x) * dx
        + (point.y - a.y) * dy
      ) / lengthSquared,
    ),
  );

  const projection = {
    x: a.x + dx * t,
    y: a.y + dy * t,
  };

  return {
    point: projection,
    t,
    distance:
      distance(
        point,
        projection,
      ),
  };
}

export function closestPointOnRoad(
  point,
  road,
) {
  let best = null;

  for (
    let segmentIndex = 0;
    segmentIndex < road.points.length - 1;
    segmentIndex += 1
  ) {
    const candidate =
      closestPointOnSegment(
        point,
        road.points[segmentIndex],
        road.points[segmentIndex + 1],
      );

    if (
      !best
      || candidate.distance
        < best.distance
    ) {
      best = {
        ...candidate,
        roadId: road.id,
        segmentIndex,
      };
    }
  }

  return best;
}

function cross(ax, ay, bx, by) {
  return ax * by - ay * bx;
}

export function segmentIntersection(
  a,
  b,
  c,
  d,
) {
  const r = {
    x: b.x - a.x,
    y: b.y - a.y,
  };

  const s = {
    x: d.x - c.x,
    y: d.y - c.y,
  };

  const denominator =
    cross(
      r.x,
      r.y,
      s.x,
      s.y,
    );

  const qpx = c.x - a.x;
  const qpy = c.y - a.y;

  if (
    Math.abs(denominator)
    <= EPSILON
  ) {
    return null;
  }

  const t =
    cross(
      qpx,
      qpy,
      s.x,
      s.y,
    ) / denominator;

  const u =
    cross(
      qpx,
      qpy,
      r.x,
      r.y,
    ) / denominator;

  if (
    t < -EPSILON
    || t > 1 + EPSILON
    || u < -EPSILON
    || u > 1 + EPSILON
  ) {
    return null;
  }

  return {
    point: {
      x: a.x + r.x * t,
      y: a.y + r.y * t,
    },
    t: Math.max(
      0,
      Math.min(1, t),
    ),
    u: Math.max(
      0,
      Math.min(1, u),
    ),
  };
}

export function angleBetweenSegments(
  a,
  b,
  c,
  d,
) {
  const first =
    normalize(
      b.x - a.x,
      b.y - a.y,
    );

  const second =
    normalize(
      d.x - c.x,
      d.y - c.y,
    );

  const dot =
    Math.max(
      -1,
      Math.min(
        1,
        first.x * second.x
        + first.y * second.y,
      ),
    );

  let degrees =
    Math.acos(
      Math.abs(dot),
    ) * 180 / Math.PI;

  if (degrees > 90) {
    degrees = 180 - degrees;
  }

  return degrees;
}

function pointSegmentDistance(
  point,
  a,
  b,
) {
  return closestPointOnSegment(
    point,
    a,
    b,
  ).distance;
}

export function segmentDistance(
  a,
  b,
  c,
  d,
) {
  if (
    segmentIntersection(
      a,
      b,
      c,
      d,
    )
  ) {
    return 0;
  }

  return Math.min(
    pointSegmentDistance(
      a,
      c,
      d,
    ),
    pointSegmentDistance(
      b,
      c,
      d,
    ),
    pointSegmentDistance(
      c,
      a,
      b,
    ),
    pointSegmentDistance(
      d,
      a,
      b,
    ),
  );
}

export function findNearestAttachment(
  point,
  roads,
  {
    maxDistance =
      ROAD_TOPOLOGY.roadSnapRadius,
    roadIds = null,
  } = {},
) {
  const allowed =
    roadIds
      ? new Set(roadIds)
      : null;

  let best = null;

  for (const road of roads) {
    if (
      allowed
      && !allowed.has(road.id)
    ) {
      continue;
    }

    const candidate =
      closestPointOnRoad(
        point,
        road,
      );

    if (
      candidate
      && candidate.distance
        <= maxDistance
      && (
        !best
        || candidate.distance
          < best.distance
      )
    ) {
      best = {
        ...candidate,
        road,
      };
    }
  }

  return best;
}

function samePoint(a, b, tolerance = 1.5) {
  return (
    distance(a, b)
    <= tolerance
  );
}

function sharedEndpointOutwardDot(
  a,
  b,
  c,
  d,
  tolerance =
    ROAD_TOPOLOGY.intersectionTolerance,
) {
  const pairs = [
    [a, b, c, d],
    [a, b, d, c],
    [b, a, c, d],
    [b, a, d, c],
  ];

  for (
    const [
      sharedFirst,
      awayFirst,
      sharedSecond,
      awaySecond,
    ]
    of pairs
  ) {
    if (
      !samePoint(
        sharedFirst,
        sharedSecond,
        tolerance,
      )
    ) {
      continue;
    }

    const first =
      normalize(
        awayFirst.x
          - sharedFirst.x,
        awayFirst.y
          - sharedFirst.y,
      );

    const second =
      normalize(
        awaySecond.x
          - sharedSecond.x,
        awaySecond.y
          - sharedSecond.y,
      );

    return (
      first.x * second.x
      + first.y * second.y
    );
  }

  return null;
}

function segmentEndpointTouch(
  intersection,
  a,
  b,
  c,
  d,
  tolerance =
    ROAD_TOPOLOGY.intersectionTolerance,
) {
  return (
    samePoint(
      intersection.point,
      a,
      tolerance,
    )
    || samePoint(
      intersection.point,
      b,
      tolerance,
    )
    || samePoint(
      intersection.point,
      c,
      tolerance,
    )
    || samePoint(
      intersection.point,
      d,
      tolerance,
    )
  );
}

function rectContainsPoint(
  rectangle,
  point,
  extra = 0,
) {
  return (
    point.x
      >= rectangle.x
        - rectangle.w / 2
        - extra
    && point.x
      <= rectangle.x
        + rectangle.w / 2
        + extra
    && point.y
      >= rectangle.y
        - rectangle.h / 2
        - extra
    && point.y
      <= rectangle.y
        + rectangle.h / 2
        + extra
  );
}

function segmentIntersectsRectangle(
  a,
  b,
  rectangle,
  extra = 0,
) {
  if (
    rectContainsPoint(
      rectangle,
      a,
      extra,
    )
    || rectContainsPoint(
      rectangle,
      b,
      extra,
    )
  ) {
    return true;
  }

  const left =
    rectangle.x
    - rectangle.w / 2
    - extra;

  const right =
    rectangle.x
    + rectangle.w / 2
    + extra;

  const top =
    rectangle.y
    - rectangle.h / 2
    - extra;

  const bottom =
    rectangle.y
    + rectangle.h / 2
    + extra;

  const corners = [
    { x: left, y: top },
    { x: right, y: top },
    { x: right, y: bottom },
    { x: left, y: bottom },
  ];

  for (
    let index = 0;
    index < 4;
    index += 1
  ) {
    if (
      segmentIntersection(
        a,
        b,
        corners[index],
        corners[(index + 1) % 4],
      )
    ) {
      return true;
    }
  }

  return false;
}

export function roadIntersectsReservation(
  road,
  reservation,
) {
  const padding =
    reservation.padding ?? 0;

  const extra =
    roadHalfWidth(
      road.class,
    );

  for (
    let index = 0;
    index < road.points.length - 1;
    index += 1
  ) {
    if (
      segmentIntersectsRectangle(
        road.points[index],
        road.points[index + 1],
        reservation,
        padding + extra,
      )
    ) {
      return true;
    }
  }

  return false;
}

export function validateRoadCandidate(
  candidate,
  existingRoads,
  {
    allowedTouchRoadIds = [],
    reservations = [],
    ignoreReservationIds = [],
  } = {},
) {
  if (
    !candidate.points
    || candidate.points.length < 2
  ) {
    return {
      ok: false,
      reason: 'too-short',
    };
  }

  if (
    polylineLength(candidate.points)
    < ROAD_TOPOLOGY.minimumJunctionSpacing
  ) {
    return {
      ok: false,
      reason: 'too-short',
    };
  }

  const allowedTouch =
    new Set(
      allowedTouchRoadIds,
    );

  const ignoredReservations =
    new Set(
      ignoreReservationIds,
    );

  for (
    const reservation
    of reservations
  ) {
    if (
      ignoredReservations.has(
        reservation.id,
      )
    ) {
      continue;
    }

    if (
      roadIntersectsReservation(
        candidate,
        reservation,
      )
    ) {
      return {
        ok: false,
        reason: 'reservation-conflict',
        reservationId:
          reservation.id,
      };
    }
  }

  for (
    let candidateSegmentIndex = 0;
    candidateSegmentIndex
      < candidate.points.length - 1;
    candidateSegmentIndex += 1
  ) {
    const a =
      candidate.points[
        candidateSegmentIndex
      ];

    const b =
      candidate.points[
        candidateSegmentIndex + 1
      ];

    for (
      const road
      of existingRoads
    ) {
      for (
        let roadSegmentIndex = 0;
        roadSegmentIndex
          < road.points.length - 1;
        roadSegmentIndex += 1
      ) {
        const c =
          road.points[
            roadSegmentIndex
          ];

        const d =
          road.points[
            roadSegmentIndex + 1
          ];

        const intersection =
          segmentIntersection(
            a,
            b,
            c,
            d,
          );

        const angle =
          angleBetweenSegments(
            a,
            b,
            c,
            d,
          );

        if (intersection) {
          const endpointTouch =
            segmentEndpointTouch(
              intersection,
              a,
              b,
              c,
              d,
            );

          if (
            endpointTouch
            && allowedTouch.has(road.id)
            && angle < ROAD_TOPOLOGY.parallelAngleDeg
          ) {
            const outwardDot = sharedEndpointOutwardDot(a, b, c, d);
            const naturalContinuation = outwardDot != null && outwardDot < -0.55;
            if (!naturalContinuation) {
              return {
                ok: false,
                reason: 'parallel-corridor-conflict',
                roadId: road.id,
                separation: 0,
              };
            }
          }

          if (
            endpointTouch
            && (
              allowedTouch.has(
                road.id,
              )
              || angle
                >= ROAD_TOPOLOGY
                  .minimumIntersectionAngleDeg
            )
          ) {
            continue;
          }

          if (
            angle
            < ROAD_TOPOLOGY
              .minimumIntersectionAngleDeg
          ) {
            return {
              ok: false,
              reason:
                'acute-intersection',
              roadId: road.id,
              point:
                intersection.point,
            };
          }

          return {
            ok: false,
            reason:
              'unplanned-intersection',
            roadId: road.id,
            point:
              intersection.point,
          };
        }

        const clearance =
          roadHalfWidth(
            candidate.class,
          )
          + roadHalfWidth(
            road.class,
          )
          + ROAD_TOPOLOGY
            .parallelClearance;

        const separation =
          segmentDistance(
            a,
            b,
            c,
            d,
          );

        if (
          angle
            < ROAD_TOPOLOGY
              .parallelAngleDeg
          && separation < clearance
        ) {
          const outwardDot =
            sharedEndpointOutwardDot(
              a,
              b,
              c,
              d,
            );

          const naturalContinuation =
            outwardDot != null
            && outwardDot < -0.55;

          if (
            !naturalContinuation
          ) {
            return {
              ok: false,
              reason:
                'parallel-corridor-conflict',
              roadId: road.id,
              separation,
            };
          }
        }
      }
    }
  }

  return {
    ok: true,
  };
}

export function snapCandidateStartToRoad(
  candidate,
  roads,
  parentRoadIds,
) {
  const attachment =
    findNearestAttachment(
      candidate.points[0],
      roads,
      {
        maxDistance:
          ROAD_TOPOLOGY
            .roadSnapRadius,
        roadIds:
          parentRoadIds,
      },
    );

  if (!attachment) {
    return {
      ok: false,
      reason:
        'missing-parent-attachment',
    };
  }

  return {
    ok: true,
    attachment,
    road: {
      ...candidate,
      points: [
        {
          ...attachment.point,
        },
        ...candidate.points.slice(1),
      ],
    },
  };
}

export function trimRoadToFirstIntersection(
  candidate,
  existingRoads,
  {
    ignoreRoadIds = [],
  } = {},
) {
  const ignored =
    new Set(ignoreRoadIds);

  let travelled = 0;
  let best = null;

  for (
    let candidateSegmentIndex = 0;
    candidateSegmentIndex
      < candidate.points.length - 1;
    candidateSegmentIndex += 1
  ) {
    const a =
      candidate.points[
        candidateSegmentIndex
      ];

    const b =
      candidate.points[
        candidateSegmentIndex + 1
      ];

    const segmentLength =
      distance(a, b);

    for (
      const road
      of existingRoads
    ) {
      if (
        ignored.has(road.id)
      ) {
        continue;
      }

      for (
        let roadSegmentIndex = 0;
        roadSegmentIndex
          < road.points.length - 1;
        roadSegmentIndex += 1
      ) {
        const intersection =
          segmentIntersection(
            a,
            b,
            road.points[
              roadSegmentIndex
            ],
            road.points[
              roadSegmentIndex + 1
            ],
          );

        if (!intersection) {
          continue;
        }

        const along =
          travelled
          + segmentLength
            * intersection.t;

        if (
          along
          <= ROAD_TOPOLOGY
            .minimumJunctionSpacing
        ) {
          continue;
        }

        const angle =
          angleBetweenSegments(
            a,
            b,
            road.points[
              roadSegmentIndex
            ],
            road.points[
              roadSegmentIndex + 1
            ],
          );

        if (
          angle
          < ROAD_TOPOLOGY
            .minimumIntersectionAngleDeg
        ) {
          continue;
        }

        if (
          !best
          || along < best.along
        ) {
          best = {
            along,
            point:
              intersection.point,
            roadId:
              road.id,
            candidateSegmentIndex,
          };
        }
      }
    }

    travelled +=
      segmentLength;
  }

  if (!best) {
    return {
      road: candidate,
      connectionRoadId: null,
    };
  }

  const points =
    candidate.points.slice(
      0,
      best.candidateSegmentIndex
        + 1,
    );

  points.push({
    ...best.point,
  });

  return {
    road: {
      ...candidate,
      points,
    },
    connectionRoadId:
      best.roadId,
  };
}

function quantizedNodeKey(
  point,
  precision = 2,
) {
  return (
    `${point.x.toFixed(precision)}:`
    + `${point.y.toFixed(precision)}`
  );
}

function addBreak(
  breakMap,
  roadId,
  segmentIndex,
  t,
  point,
) {
  const key =
    `${roadId}:${segmentIndex}`;

  if (!breakMap.has(key)) {
    breakMap.set(
      key,
      [],
    );
  }

  const breaks =
    breakMap.get(key);

  if (
    breaks.some(
      (candidate) =>
        Math.abs(candidate.t - t)
        <= 1e-6,
    )
  ) {
    return;
  }

  breaks.push({
    t,
    point,
  });
}

export function compileRoadGraph(
  roads,
) {
  const breakMap =
    new Map();

  for (
    const road
    of roads
  ) {
    for (
      let segmentIndex = 0;
      segmentIndex
        < road.points.length - 1;
      segmentIndex += 1
    ) {
      addBreak(
        breakMap,
        road.id,
        segmentIndex,
        0,
        road.points[
          segmentIndex
        ],
      );

      addBreak(
        breakMap,
        road.id,
        segmentIndex,
        1,
        road.points[
          segmentIndex + 1
        ],
      );
    }
  }

  for (
    let firstRoadIndex = 0;
    firstRoadIndex < roads.length;
    firstRoadIndex += 1
  ) {
    const firstRoad =
      roads[firstRoadIndex];

    for (
      let secondRoadIndex =
        firstRoadIndex + 1;
      secondRoadIndex < roads.length;
      secondRoadIndex += 1
    ) {
      const secondRoad =
        roads[secondRoadIndex];

      for (
        let firstSegmentIndex = 0;
        firstSegmentIndex
          < firstRoad.points.length - 1;
        firstSegmentIndex += 1
      ) {
        for (
          let secondSegmentIndex = 0;
          secondSegmentIndex
            < secondRoad.points.length - 1;
          secondSegmentIndex += 1
        ) {
          const intersection =
            segmentIntersection(
              firstRoad.points[
                firstSegmentIndex
              ],
              firstRoad.points[
                firstSegmentIndex + 1
              ],
              secondRoad.points[
                secondSegmentIndex
              ],
              secondRoad.points[
                secondSegmentIndex + 1
              ],
            );

          if (!intersection) {
            continue;
          }

          addBreak(
            breakMap,
            firstRoad.id,
            firstSegmentIndex,
            intersection.t,
            intersection.point,
          );

          addBreak(
            breakMap,
            secondRoad.id,
            secondSegmentIndex,
            intersection.u,
            intersection.point,
          );
        }
      }
    }
  }

  const nodes = [];
  const nodeByKey =
    new Map();

  const getNodeId = (
    point,
  ) => {
    const key =
      quantizedNodeKey(
        point,
      );

    if (
      nodeByKey.has(key)
    ) {
      return nodeByKey.get(
        key,
      );
    }

    const id =
      `junction-${nodes.length + 1}`;

    nodes.push({
      id,
      x: point.x,
      y: point.y,
      roadIds: [],
      degree: 0,
    });

    nodeByKey.set(
      key,
      id,
    );

    return id;
  };

  const graphEdges = [];

  for (
    const road
    of roads
  ) {
    for (
      let segmentIndex = 0;
      segmentIndex
        < road.points.length - 1;
      segmentIndex += 1
    ) {
      const key =
        `${road.id}:${segmentIndex}`;

      const breaks = [
        ...(breakMap.get(key)
          ?? []),
      ].sort(
        (a, b) =>
          a.t - b.t,
      );

      for (
        let breakIndex = 0;
        breakIndex
          < breaks.length - 1;
        breakIndex += 1
      ) {
        const from =
          breaks[breakIndex];

        const to =
          breaks[breakIndex + 1];

        if (
          distance(
            from.point,
            to.point,
          ) <= 0.5
        ) {
          continue;
        }

        const fromNodeId =
          getNodeId(
            from.point,
          );

        const toNodeId =
          getNodeId(
            to.point,
          );

        graphEdges.push({
          id:
            `${road.id}::`
            + `${segmentIndex}:`
            + breakIndex,
          roadId: road.id,
          roadClass:
            road.class,
          fromNodeId,
          toNodeId,
          points: [
            { ...from.point },
            { ...to.point },
          ],
          length:
            distance(
              from.point,
              to.point,
            ),
        });
      }
    }
  }

  const nodeMap =
    new Map(
      nodes.map(
        (node) => [
          node.id,
          node,
        ],
      ),
    );

  for (
    const edge
    of graphEdges
  ) {
    for (
      const nodeId
      of [
        edge.fromNodeId,
        edge.toNodeId,
      ]
    ) {
      const node =
        nodeMap.get(nodeId);

      node.degree += 1;

      if (
        !node.roadIds.includes(
          edge.roadId,
        )
      ) {
        node.roadIds.push(
          edge.roadId,
        );
      }
    }
  }

  return {
    nodes,
    edges: graphEdges,
    junctions:
      nodes.filter(
        (node) =>
          node.degree >= 3
          || node.roadIds.length
            >= 2,
      ),
  };
}

export function roadCorridorsConflict(
  firstRoad,
  secondRoad,
) {
  for (
    let firstIndex = 0;
    firstIndex
      < firstRoad.points.length - 1;
    firstIndex += 1
  ) {
    for (
      let secondIndex = 0;
      secondIndex
        < secondRoad.points.length - 1;
      secondIndex += 1
    ) {
      const a =
        firstRoad.points[
          firstIndex
        ];

      const b =
        firstRoad.points[
          firstIndex + 1
        ];

      const c =
        secondRoad.points[
          secondIndex
        ];

      const d =
        secondRoad.points[
          secondIndex + 1
        ];

      const intersection =
        segmentIntersection(
          a,
          b,
          c,
          d,
        );

      if (intersection) {
        if (
          segmentEndpointTouch(
            intersection,
            a,
            b,
            c,
            d,
          )
        ) {
          continue;
        }

        return {
          conflict: true,
          reason: 'intersection',
          point:
            intersection.point,
        };
      }

      const angle =
        angleBetweenSegments(
          a,
          b,
          c,
          d,
        );

      const clearance =
        roadHalfWidth(
          firstRoad.class,
        )
        + roadHalfWidth(
          secondRoad.class,
        )
        + ROAD_TOPOLOGY
          .parallelClearance;

      const separation =
        segmentDistance(
          a,
          b,
          c,
          d,
        );

      if (
        angle
          < ROAD_TOPOLOGY
            .parallelAngleDeg
        && separation
          < clearance
      ) {
        const outwardDot =
          sharedEndpointOutwardDot(
            a,
            b,
            c,
            d,
          );

        if (
          outwardDot != null
          && outwardDot < -0.55
        ) {
          continue;
        }

        return {
          conflict: true,
          reason:
            'parallel-overlap',
          separation,
        };
      }
    }
  }

  return {
    conflict: false,
  };
}
