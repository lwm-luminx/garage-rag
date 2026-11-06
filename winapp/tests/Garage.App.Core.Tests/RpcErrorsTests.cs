using Garage.App.Core.Backend;
using Grpc.Core;

namespace Garage.App.Core.Tests;

public sealed class RpcErrorsTests
{
    private static RpcException Error(StatusCode code, string detail) => new(new Status(code, detail));

    // What garage serve sent the Search page against a database missing migration 014.
    private const string DatabaseError = """
        Exception calling application: (psycopg.errors.UndefinedColumn) column c.direction does not exist
        LINE 36:                c.direction,
                                ^
        [SQL:
                WITH
                vec AS (
                    SELECT c.id AS chunk_id,
        [parameters: {'qv': '[-0.023844264,0.0020821912, ...]', 'q': 'garage'}]
        (Background on this error at: https://sqlalche.me/e/21/f405)
        """;

    [Fact]
    public void A_database_error_shows_only_what_happened() =>
        Assert.Equal("column c.direction does not exist", RpcErrors.Describe(Error(StatusCode.Unknown, DatabaseError)));

    [Fact]
    public void A_plain_detail_is_kept() =>
        Assert.Equal("no such source: notes", RpcErrors.Describe(Error(StatusCode.NotFound, "no such source: notes")));

    [Fact]
    public void An_empty_detail_names_the_status_code() =>
        Assert.Equal("Unavailable", RpcErrors.Describe(Error(StatusCode.Unavailable, "  \n ")));

    [Fact]
    public void A_long_first_line_is_cut_with_an_ellipsis()
    {
        string described = RpcErrors.Describe(Error(StatusCode.Internal, new string('x', 1000)));
        Assert.Equal(RpcErrors.MaxLength, described.Length);
        Assert.EndsWith("…", described, StringComparison.Ordinal);
    }
}
