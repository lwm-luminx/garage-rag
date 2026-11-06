using Grpc.Core;

namespace Garage.App.Core.Backend;

/// <summary>
/// Server errors worded for a page. The Python server puts the whole exception in the status detail,
/// which for a database error is the full SQL statement and its parameters (a query's embedding among
/// them): kilobytes no page can show. A page shows the first line, the part that says what happened.
/// </summary>
public static class RpcErrors
{
    /// <summary>The longest message a page shows; longer first lines end in an ellipsis.</summary>
    public const int MaxLength = 300;

    /// <summary>
    /// "column c.direction does not exist" from a psycopg error; the status code's name when the
    /// server said nothing.
    /// </summary>
    public static string Describe(RpcException ex)
    {
        ArgumentNullException.ThrowIfNull(ex);
        string? line = ex.Status.Detail?
            .Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .FirstOrDefault();
        if (string.IsNullOrEmpty(line))
        {
            return ex.StatusCode.ToString();
        }
        line = StripWrapper(line);
        return line.Length <= MaxLength ? line : line[..(MaxLength - 1)] + "…";
    }

    // "Exception calling application: (psycopg.errors.UndefinedColumn) column c.direction does not exist"
    // → "column c.direction does not exist": grpc's prefix and SQLAlchemy's exception-class tag say
    // nothing to a reader.
    private static string StripWrapper(string line)
    {
        const string prefix = "Exception calling application:";
        if (line.StartsWith(prefix, StringComparison.Ordinal))
        {
            line = line[prefix.Length..].TrimStart();
        }
        if (line.StartsWith('(') && line.IndexOf(") ", StringComparison.Ordinal) is var close and > 0)
        {
            line = line[(close + 2)..];
        }
        return line;
    }
}
