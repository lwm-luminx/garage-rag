namespace Garage.App.Core.Graph;

/// <summary>
/// Where the Graph page draws each vertex of a neighbourhood: the center in the middle and every
/// other vertex on a ring for its hop distance, spread around the ring near the vertices it hangs off.
/// A port of the Mac's <c>GraphLayout</c>, so the same neighbourhood looks the same on both.
/// </summary>
/// <remarks>Deterministic, with no simulation to settle, so a unit test can hold it.</remarks>
public sealed class GraphLayout
{
    /// <summary>Each vertex's position, in the coordinates of the size given.</summary>
    public IReadOnlyDictionary<long, GraphPoint> Positions { get; }

    /// <summary>Each vertex's hop distance from the center; the center is 0.</summary>
    public IReadOnlyDictionary<long, int> Rings { get; }

    /// <summary>The center's position.</summary>
    public GraphPoint Origin { get; }

    /// <summary>Hops from the center to the farthest vertex.</summary>
    public int Depth { get; }

    /// <summary>
    /// The layout of <paramref name="neighborhood"/> inside a <paramref name="width"/> by
    /// <paramref name="height"/> area, keeping <paramref name="margin"/> clear at every edge. A vertex no
    /// edge connects to the center (a filter can leave one) is placed on the outermost ring.
    /// </summary>
    public GraphLayout(GraphNeighborhood neighborhood, double width, double height, double margin = 32)
    {
        ArgumentNullException.ThrowIfNull(neighborhood);
        Origin = new(width / 2, height / 2);
        var positions = new Dictionary<long, GraphPoint>();
        var rings = new Dictionary<long, int>();
        Positions = positions;
        Rings = rings;
        if (neighborhood.Center is not { } center)
        {
            return;
        }

        var ids = neighborhood.Vertices.Select(v => v.Id).ToHashSet();
        var neighbours = new Dictionary<long, List<long>>();
        foreach (GraphEdgeItem edge in neighborhood.Edges.Where(e => ids.Contains(e.SourceId) && ids.Contains(e.TargetId)))
        {
            Neighbours(edge.SourceId).Add(edge.TargetId);
            Neighbours(edge.TargetId).Add(edge.SourceId);
        }

        // Breadth first from the center gives each vertex its ring.
        rings[center.Id] = 0;
        List<long> frontier = [center.Id];
        while (frontier.Count > 0)
        {
            List<long> next = [];
            foreach (long id in frontier)
            {
                foreach (long other in Neighbours(id).Order())
                {
                    if (!rings.ContainsKey(other))
                    {
                        rings[other] = rings[id] + 1;
                        next.Add(other);
                    }
                }
            }
            frontier = next;
        }
        int reached = rings.Values.Max();
        List<long> strays = [.. neighborhood.Vertices.Select(v => v.Id).Where(id => !rings.ContainsKey(id))];
        int depth = strays.Count == 0 ? reached : reached + 1;
        foreach (long id in strays)
        {
            rings[id] = depth;
        }
        Depth = depth;

        double radius = Math.Max(0, Math.Min(width, height) / 2 - margin);
        positions[center.Id] = Origin;
        var angles = new Dictionary<long, double> { [center.Id] = 0 };
        var titles = new Dictionary<long, (string Label, string Title)>();
        foreach (GraphVertexItem vertex in neighborhood.Vertices)
        {
            titles[vertex.Id] = (vertex.Label, vertex.Title);
        }

        for (int ring = 1; ring <= depth; ring++)
        {
            List<long> members = [.. rings.Where(r => r.Value == ring).Select(r => r.Key)];
            if (members.Count == 0)
            {
                continue;
            }
            // A vertex wants the angle of the ring-inward vertices it hangs off; the first ring, with
            // nothing inward but the center, is ordered by label then title so like sits with like.
            int inwardRing = ring - 1;
            var preferred = members.ToDictionary(id => id, id =>
            {
                List<double> inward = [.. Neighbours(id).Where(n => rings[n] == inwardRing && angles.ContainsKey(n)).Select(n => angles[n])];
                return inward.Count == 0 ? 0 : MeanAngle(inward);
            });
            List<long> ordered = ring == 1
                ? [.. members.Order(Comparer<long>.Create((a, b) =>
                {
                    (string la, string ta) = titles.GetValueOrDefault(a, ("", ""));
                    (string lb, string tb) = titles.GetValueOrDefault(b, ("", ""));
                    int byLabel = string.CompareOrdinal(la, lb);
                    if (byLabel != 0)
                    {
                        return byLabel;
                    }
                    int byTitle = string.CompareOrdinal(ta, tb);
                    return byTitle != 0 ? byTitle : a.CompareTo(b);
                }))]
                : [.. members.OrderBy(id => preferred[id]).ThenBy(id => id)];
            // The first ring is spaced evenly from the top. Farther rings keep each vertex at its
            // preferred angle, on its parent's side of the picture, pushed apart where they collide.
            IReadOnlyList<double> placed = ring == 1
                ? EvenlySpaced(ordered.Count, -Math.PI / 2)
                : SpreadApart([.. ordered.Select(id => preferred[id])]);
            double ringRadius = radius * ring / depth;
            for (int index = 0; index < ordered.Count; index++)
            {
                double angle = placed[index];
                angles[ordered[index]] = angle;
                positions[ordered[index]] = new(Origin.X + ringRadius * Math.Cos(angle), Origin.Y + ringRadius * Math.Sin(angle));
            }
        }

        List<long> Neighbours(long id)
        {
            if (!neighbours.TryGetValue(id, out List<long>? list))
            {
                list = [];
                neighbours[id] = list;
            }
            return list;
        }
    }

    /// <summary>The vertex whose drawn circle of <paramref name="radius"/> is under <paramref name="point"/>, nearest first.</summary>
    public long? VertexAt(GraphPoint point, double radius)
    {
        long? best = null;
        double bestDistance = double.MaxValue;
        foreach ((long id, GraphPoint position) in Positions)
        {
            double distance = Math.Sqrt(Math.Pow(position.X - point.X, 2) + Math.Pow(position.Y - point.Y, 2));
            if (distance <= radius && distance < bestDistance)
            {
                best = id;
                bestDistance = distance;
            }
        }
        return best;
    }

    /// <summary><paramref name="count"/> angles a full turn apart from each other, the first at <paramref name="start"/>.</summary>
    public static IReadOnlyList<double> EvenlySpaced(int count, double start)
    {
        if (count <= 0)
        {
            return [];
        }
        double step = 2 * Math.PI / count;
        return [.. Enumerable.Range(0, count).Select(i => start + step * i)];
    }

    /// <summary>
    /// Angles as near their preferred values (given in ascending order) as a minimum separation
    /// allows: neighbours that collide are pushed apart, the whole group is re-centred on where it
    /// wanted to be, and a ring too crowded for that falls back to even spacing. The separation is a
    /// full turn over the count, and never more than <paramref name="maxSeparation"/>.
    /// </summary>
    public static IReadOnlyList<double> SpreadApart(IReadOnlyList<double> preferred, double maxSeparation = Math.PI / 6)
    {
        ArgumentNullException.ThrowIfNull(preferred);
        if (preferred.Count <= 1)
        {
            return preferred;
        }
        double separation = Math.Min(2 * Math.PI / preferred.Count, maxSeparation);
        double[] angles = [.. preferred];
        for (int i = 1; i < angles.Length; i++)
        {
            angles[i] = Math.Max(angles[i], angles[i - 1] + separation);
        }
        double drift = angles.Zip(preferred, (a, p) => a - p).Sum() / angles.Length;
        for (int i = 0; i < angles.Length; i++)
        {
            angles[i] -= drift;
        }
        if (angles[^1] - angles[0] >= 2 * Math.PI - separation - 0.0001)
        {
            return EvenlySpaced(preferred.Count, preferred[0]);
        }
        return angles;
    }

    /// <summary>The circular mean of angles, so angles either side of the wrap average to the wrap.</summary>
    public static double MeanAngle(IReadOnlyList<double> angles)
    {
        ArgumentNullException.ThrowIfNull(angles);
        return Math.Atan2(angles.Sum(Math.Sin), angles.Sum(Math.Cos));
    }
}
