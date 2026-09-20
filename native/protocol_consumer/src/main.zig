const std = @import("std");

const Allocator = std.mem.Allocator;
const IpAddress = std.Io.net.IpAddress;
const Stream = std.Io.net.Stream;
const Value = std.json.Value;
const JsonDocument = std.json.Parsed(Value);
const ByteList = std.array_list.Managed(u8);

const response_limit: usize = 4 * 1024 * 1024;
const sse_limit: usize = 64 * 1024;
const payload = "BRL8U5TDfAAE//wEDKw2QgDNy7gzTIhP";
const timeout: std.Io.Timeout = .{ .duration = .{
    .clock = .awake,
    .raw = .fromSeconds(5),
} };

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    defer args.deinit();
    _ = args.next();
    const descriptor_path = args.next() orelse {
        std.debug.print("usage: wotex-tracker-protocol-consumer DESCRIPTOR\n", .{});
        return error.MissingDescriptor;
    };
    if (args.next() != null) return error.UnexpectedArgument;

    const descriptor_bytes = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        descriptor_path,
        init.gpa,
        .limited(response_limit),
    );
    defer init.gpa.free(descriptor_bytes);
    var descriptor = try parseJson(init.gpa, descriptor_bytes);
    defer descriptor.deinit();

    if (optionalString(&descriptor.value, "mode")) |mode| {
        if (std.mem.eql(u8, mode, "integrated_product")) {
            try integratedProduct(init, &descriptor.value);
            return;
        }
    }
    try releaseProbe(init, &descriptor.value);
}

fn releaseProbe(init: std.process.Init, descriptor: *const Value) !void {
    const allocator = init.gpa;
    const origin = try requiredString(descriptor, "url");
    const scope = try requiredString(descriptor, "scope");
    const token = try requiredString(descriptor, "token");
    const reader = try requiredString(descriptor, "reader");
    try validatePathComponent(scope);
    try validateHeaderValue(token);
    try validateHeaderValue(reader);

    const parsed_origin = try parseOrigin(origin);
    const client = Client{
        .allocator = allocator,
        .io = init.io,
        .address = parsed_origin.address,
        .authority = parsed_origin.authority,
        .token = token,
    };
    const prefix = try std.fmt.allocPrint(allocator, "/api/v1/scopes/{s}", .{scope});
    defer allocator.free(prefix);

    var spec = try client.call("GET", "/api/v1/openapi.json", null, null, null, 200);
    defer spec.deinit();
    try expectString(try field(&spec.value, "openapi"), "3.1.0", "OpenAPI version");
    _ = try path(&spec.value, &.{ "paths", "/api/v1/scopes/{scope}/observations" });

    const capabilities_path = try appendPath(allocator, prefix, "/capabilities");
    defer allocator.free(capabilities_path);
    var unauthorized = try client.call("GET", capabilities_path, "", null, null, 401);
    defer unauthorized.deinit();
    try expectString(try path(&unauthorized.value, &.{ "error", "code" }), "unauthorized", "missing credential");

    const state_path = try appendPath(allocator, prefix, "/state");
    defer allocator.free(state_path);
    var initial = try client.call("GET", state_path, reader, null, null, 200);
    defer initial.deinit();
    try expectString(try path(&initial.value, &.{ "data", "generation" }), "0", "initial generation");
    const cursor = try stringValue(try path(&initial.value, &.{ "data", "stream_cursor" }));

    const rejected_path = try std.fmt.allocPrint(allocator, "/api/v9/scopes/{s}/state", .{scope});
    defer allocator.free(rejected_path);
    var rejected = try client.call("GET", rejected_path, reader, null, null, 404);
    defer rejected.deinit();

    const observation =
        "{\"schema\":\"wtr.observation.v1\",\"id\":\"native-client-observation\",\"observed_at\":1700000000000," ++
        "\"ingress\":\"ble\",\"source\":{\"integer\":1,\"float\":1.0,\"wide\":9007199254740993,\"zero\":0," ++
        "\"false\":false,\"null\":null},\"addressing\":{\"mac\":\"private-native-fixture\"},\"radio\":{}," ++
        "\"transport\":{\"manufacturer_id\":1177},\"provenance\":{\"kind\":\"fixture\"}," ++
        "\"payload\":{\"kind\":\"bytes\",\"encoding\":\"base64\",\"data\":\"" ++ payload ++ "\"}}";
    const import_body = try std.fmt.allocPrint(
        allocator,
        "{{\"observation\":{s},\"expected_generation\":\"0\"}}",
        .{observation},
    );
    defer allocator.free(import_body);
    const import_path = try appendPath(allocator, prefix, "/observations");
    defer allocator.free(import_path);
    const import_key = "00000000-0000-4000-8000-000000000001";

    var forbidden = try client.call("POST", import_path, reader, import_body, import_key, 403);
    defer forbidden.deinit();
    try expectString(try path(&forbidden.value, &.{ "error", "code" }), "forbidden", "reader write rejection");

    var imported = try client.call("POST", import_path, null, import_body, import_key, 200);
    defer imported.deinit();
    try expectString(try path(&imported.value, &.{ "data", "generation" }), "1", "import generation");
    var replayed = try client.call("POST", import_path, null, import_body, import_key, 200);
    defer replayed.deinit();
    try expect(jsonEqual(&imported.value, &replayed.value), "idempotent replay");

    const conflicting_import = try std.fmt.allocPrint(
        allocator,
        "{{\"observation\":{s},\"expected_generation\":\"1\"}}",
        .{observation},
    );
    defer allocator.free(conflicting_import);
    var conflict = try client.call("POST", import_path, null, conflicting_import, import_key, 409);
    defer conflict.deinit();
    try expectString(try path(&conflict.value, &.{ "error", "outcome" }), "not_committed", "idempotency conflict outcome");

    const operation_path = try std.fmt.allocPrint(allocator, "{s}/operations/{s}", .{ prefix, import_key });
    defer allocator.free(operation_path);
    var operation = try client.call("GET", operation_path, null, null, null, 200);
    defer operation.deinit();
    try expect(
        jsonEqual(try field(&operation.value, "data"), try field(&imported.value, "data")),
        "idempotency operation receipt",
    );

    const observation_id = try stringValue(try path(&imported.value, &.{ "data", "data", "observation_id" }));
    try validatePathComponent(observation_id);
    const raw_path = try std.fmt.allocPrint(allocator, "{s}/observations/{s}/raw", .{ prefix, observation_id });
    defer allocator.free(raw_path);
    var raw = try client.call("GET", raw_path, null, null, null, 200);
    defer raw.deinit();
    try expectInteger(try path(&raw.value, &.{ "source", "integer" }), 1, "raw integer");
    try expectNumber(try path(&raw.value, &.{ "source", "float" }), 1.0, "raw float");
    try expectInteger(try path(&raw.value, &.{ "source", "wide" }), 9_007_199_254_740_993, "raw wide integer");
    try expectBool(try path(&raw.value, &.{ "source", "false" }), false, "raw false");
    try expectNull(try path(&raw.value, &.{ "source", "null" }), "raw null");

    const enrollment_body = try jsonObjectWithString(
        allocator,
        "observation_id",
        observation_id,
        ",\"title\":\"Native client sensor\",\"owner_confirmed\":true,\"expected_generation\":\"1\"",
    );
    defer allocator.free(enrollment_body);
    const enrollments_path = try appendPath(allocator, prefix, "/enrollments");
    defer allocator.free(enrollments_path);
    var enrolled = try client.call(
        "POST",
        enrollments_path,
        null,
        enrollment_body,
        "00000000-0000-4000-8000-000000000002",
        200,
    );
    defer enrolled.deinit();
    const thing = try stringValue(try path(&enrolled.value, &.{ "data", "data", "thing_id" }));
    try validatePathComponent(thing);

    const materialization_body = try jsonObjectWithString(
        allocator,
        "thing_id",
        thing,
        ",\"expected_generation\":\"2\"",
    );
    defer allocator.free(materialization_body);
    const materializations_path = try appendPath(allocator, prefix, "/materialisations");
    defer allocator.free(materializations_path);
    var materialized = try client.call(
        "POST",
        materializations_path,
        null,
        materialization_body,
        "00000000-0000-4000-8000-000000000003",
        200,
    );
    defer materialized.deinit();
    try expectString(try path(&materialized.value, &.{ "data", "generation" }), "3", "materialization generation");

    const property_path = try std.fmt.allocPrint(
        allocator,
        "{s}/things/{s}/properties/temperature",
        .{ prefix, thing },
    );
    defer allocator.free(property_path);
    var property = try client.call("GET", property_path, reader, null, null, 200);
    defer property.deinit();
    try expectNumber(&property.value, 24.3, "temperature property");

    const history_path = try std.fmt.allocPrint(allocator, "{s}/things/{s}/history", .{ prefix, thing });
    defer allocator.free(history_path);
    var thing_history = try client.call("GET", history_path, reader, null, null, 200);
    defer thing_history.deinit();
    try expectString(
        try field(try index(try path(&thing_history.value, &.{ "data", "items" }), 0, "history item"), "generation"),
        "3",
        "history generation",
    );

    const query_base = try makeQuery(allocator, thing, "native-temperature-history", 1_700_000_000_001, 1);
    defer allocator.free(query_base);
    const query = try identifyQuery(allocator, query_base);
    defer allocator.free(query);
    const analytics_path = try appendPath(allocator, prefix, "/analytics/query");
    defer allocator.free(analytics_path);
    var analytics = try client.call("POST", analytics_path, reader, query, null, 200);
    defer analytics.deinit();
    try expectInteger(try path(&analytics.value, &.{ "data", "qualified_rows" }), 1, "qualified analytics rows");
    try expectNumber(
        try field(
            try index(
                try path(try index(try path(&analytics.value, &.{ "data", "series" }), 0, "analytics series"), &.{"points"}),
                0,
                "analytics point",
            ),
            "value",
        ),
        24.3,
        "analytics point value",
    );

    const forged = try replaceIdentity(allocator, query, "wtr-json-v1:sha256:0000000000000000000000000000000000000000000000000000000000000000");
    defer allocator.free(forged);
    var invalid_identity = try client.call("POST", analytics_path, reader, forged, null, 400);
    defer invalid_identity.deinit();
    try expectString(try path(&invalid_identity.value, &.{ "error", "code" }), "invalid_request", "forged query identity");

    const paged_base = try makeQuery(allocator, thing, "native-temperature-pages", 1_700_000_000_002, 2);
    defer allocator.free(paged_base);
    const paged_query = try identifyQuery(allocator, paged_base);
    defer allocator.free(paged_query);
    const first_request = try makePageRequest(allocator, paged_query, null, 1);
    defer allocator.free(first_request);
    const pages_path = try appendPath(allocator, prefix, "/analytics/pages");
    defer allocator.free(pages_path);
    var first_page = try client.call("POST", pages_path, reader, first_request, null, 200);
    defer first_page.deinit();
    const first = try field(&first_page.value, "data");
    try expectInteger(try path(first, &.{ "page", "index" }), 0, "first page index");
    try expectNumber(
        try field(
            try index(
                try path(try index(try path(first, &.{ "result", "series" }), 0, "paged series"), &.{"points"}),
                0,
                "paged point",
            ),
            "value",
        ),
        24.3,
        "paged point value",
    );
    const page_cursor = try stringValue(try field(first, "cursor"));
    const continued = try makePageRequest(allocator, paged_query, page_cursor, 1);
    defer allocator.free(continued);
    var second_page = try client.call("POST", pages_path, reader, continued, null, 200);
    defer second_page.deinit();
    const second = try field(&second_page.value, "data");
    try expectInteger(try path(second, &.{ "page", "index" }), 1, "second page index");
    try expect(jsonEqual(try field(second, "generation"), try field(first, "generation")), "page generation pin");
    try expect(jsonEqual(try path(second, &.{ "result", "snapshot" }), try path(first, &.{ "result", "snapshot" })), "page snapshot pin");
    try expectArrayLength(
        try path(try index(try path(second, &.{ "result", "series" }), 0, "second series"), &.{"points"}),
        0,
        "empty second page",
    );
    try expectNull(try field(second, "cursor"), "terminal page cursor");
    const altered = try makePageRequest(allocator, paged_query, page_cursor, 2);
    defer allocator.free(altered);
    var invalid_cursor = try client.call("POST", pages_path, reader, altered, null, 400);
    defer invalid_cursor.deinit();
    try expectString(try path(&invalid_cursor.value, &.{ "error", "code" }), "invalid_cursor", "cursor request binding");

    const stream_path = try std.fmt.allocPrint(allocator, "{s}/events/stream?cursor={s}", .{ prefix, cursor });
    defer allocator.free(stream_path);
    var events = try client.streamEvents(stream_path, reader, null, 3);
    defer events.deinit(allocator);
    try expect(events.items.items.len == 3, "SSE event count");
    try expectStringSlice(events.items.items[0].id, "1", "first SSE event");
    try expectStringSlice(events.items.items[1].id, "2", "second SSE event");
    try expectStringSlice(events.items.items[2].id, "3", "third SSE event");
    const events_path = try appendPath(allocator, prefix, "/events/stream");
    defer allocator.free(events_path);
    var resumed = try client.streamEvents(events_path, reader, events.items.items[1].cursor, 1);
    defer resumed.deinit(allocator);
    try expectStringSlice(resumed.items.items[0].id, "3", "resumed SSE event");

    const saved_id = "native-temperature";
    const saved_body = try makeSavedQuery(allocator, saved_id, query);
    defer allocator.free(saved_body);
    const saved_queries_path = try appendPath(allocator, prefix, "/saved_queries");
    defer allocator.free(saved_queries_path);
    const save_key = "00000000-0000-4000-8000-000000000005";
    var saved_forbidden = try client.call("POST", saved_queries_path, reader, saved_body, save_key, 403);
    defer saved_forbidden.deinit();
    try expectString(try path(&saved_forbidden.value, &.{ "error", "code" }), "forbidden", "reader saved-query rejection");
    var saved_receipt = try client.call("POST", saved_queries_path, null, saved_body, save_key, 200);
    defer saved_receipt.deinit();
    try expectString(try path(&saved_receipt.value, &.{ "data", "generation" }), "4", "saved-query generation");

    var pinned_page = try client.call("POST", pages_path, reader, continued, null, 200);
    defer pinned_page.deinit();
    try expect(jsonEqual(try path(&pinned_page.value, &.{ "data", "generation" }), try field(first, "generation")), "cursor survives unrelated commit");
    try expect(jsonEqual(try path(&pinned_page.value, &.{ "data", "result", "snapshot" }), try path(first, &.{ "result", "snapshot" })), "cursor snapshot survives unrelated commit");

    const saved_path = try std.fmt.allocPrint(allocator, "{s}/saved_queries/{s}", .{ prefix, saved_id });
    defer allocator.free(saved_path);
    var definition = try client.call("GET", saved_path, null, null, null, 200);
    defer definition.deinit();
    var expected_query = try parseJson(allocator, query);
    defer expected_query.deinit();
    try expect(jsonEqual(try path(&definition.value, &.{ "data", "value", "query" }), &expected_query.value), "saved query definition");

    const execute_path = try appendPath(allocator, saved_path, "/execute");
    defer allocator.free(execute_path);
    var executed = try client.call("GET", execute_path, null, null, null, 200);
    defer executed.deinit();
    try expect(jsonEqual(try path(&executed.value, &.{ "data", "spec" }), &expected_query.value), "saved query execution spec");
    try expectNumber(
        try field(
            try index(
                try path(try index(try path(&executed.value, &.{ "data", "series" }), 0, "saved-query series"), &.{"points"}),
                0,
                "saved-query point",
            ),
            "value",
        ),
        24.3,
        "saved-query point value",
    );

    const delete_body = try jsonObjectWithString(allocator, "id", saved_id, ",\"expected_generation\":\"4\"");
    defer allocator.free(delete_body);
    const deletions_path = try appendPath(allocator, prefix, "/saved_query_deletions");
    defer allocator.free(deletions_path);
    var deleted = try client.call(
        "POST",
        deletions_path,
        null,
        delete_body,
        "00000000-0000-4000-8000-000000000006",
        200,
    );
    defer deleted.deinit();
    try expectString(try path(&deleted.value, &.{ "data", "generation" }), "5", "saved-query deletion generation");
    var missing_saved = try client.call("GET", saved_path, null, null, null, 404);
    defer missing_saved.deinit();
    const saved_history_path = try appendPath(allocator, saved_path, "/history");
    defer allocator.free(saved_history_path);
    var saved_history = try client.call("GET", saved_history_path, null, null, null, 200);
    defer saved_history.deinit();
    const history_items = try path(&saved_history.value, &.{ "data", "items" });
    try expectBool(try field(try index(history_items, 0, "saved-query creation history"), "deleted"), false, "saved-query creation state");
    try expectBool(try field(try index(history_items, 1, "saved-query deletion history"), "deleted"), true, "saved-query deletion state");

    var latest = try client.call("GET", state_path, reader, null, null, 200);
    defer latest.deinit();
    const latest_cursor = try stringValue(try path(&latest.value, &.{ "data", "stream_cursor" }));
    var active = try client.openReadyStream(events_path, reader, latest_cursor);
    defer active.close(init.io);

    const revoke_body = "{\"credential_id\":\"reader\",\"expected_generation\":\"5\"}";
    const revocations_path = try appendPath(allocator, prefix, "/revocations");
    defer allocator.free(revocations_path);
    var revoked = try client.call(
        "POST",
        revocations_path,
        null,
        revoke_body,
        "00000000-0000-4000-8000-000000000004",
        200,
    );
    defer revoked.deinit();
    try expectString(try path(&revoked.value, &.{ "data", "generation" }), "6", "revocation generation");
    var revoked_page = try client.call("POST", pages_path, reader, continued, null, 401);
    defer revoked_page.deinit();
    try expectString(try path(&revoked_page.value, &.{ "error", "code" }), "unauthorized", "revoked page credential");
    try expectStreamClosed(init.io, &active);
    var revoked_state = try client.call("GET", state_path, reader, null, null, 401);
    defer revoked_state.deinit();
    try expectString(try path(&revoked_state.value, &.{ "error", "code" }), "unauthorized", "revoked state credential");

    std.debug.print(
        "NATIVE_PROTOCOL_PASS openapi=true version_rejection=true enrollment=true observation=true " ++
            "idempotency_conflict=true native_types=true property=true history=true analytics=true " ++
            "analytics_pages=true saved_queries=true sse_resume=true active_stream_revocation=true\n",
        .{},
    );
}

fn integratedProduct(init: std.process.Init, descriptor: *const Value) !void {
    const allocator = init.gpa;
    const origin = try requiredString(descriptor, "url");
    const scope = try requiredString(descriptor, "scope");
    const token = try requiredString(descriptor, "token");
    const revoked_token = try requiredString(descriptor, "revoked");
    const thing = try requiredString(descriptor, "thing");
    const generation = try requiredString(descriptor, "generation");
    const history_generation = try requiredString(descriptor, "history_generation");
    try validatePathComponent(scope);
    try validatePathComponent(thing);
    try validateHeaderValue(token);
    try validateHeaderValue(revoked_token);

    const parsed_origin = try parseOrigin(origin);
    const client = Client{
        .allocator = allocator,
        .io = init.io,
        .address = parsed_origin.address,
        .authority = parsed_origin.authority,
        .token = token,
    };
    const prefix = try std.fmt.allocPrint(allocator, "/api/v1/scopes/{s}", .{scope});
    defer allocator.free(prefix);

    const state_path = try appendPath(allocator, prefix, "/state");
    defer allocator.free(state_path);
    var state = try client.call("GET", state_path, null, null, null, 200);
    defer state.deinit();
    try expectString(try path(&state.value, &.{ "data", "generation" }), generation, "integrated generation");

    const property_path = try std.fmt.allocPrint(allocator, "{s}/things/{s}/properties/temperature", .{ prefix, thing });
    defer allocator.free(property_path);
    var property = try client.call("GET", property_path, null, null, null, 200);
    defer property.deinit();
    try expectNumber(&property.value, 24.3, "integrated temperature");

    const history_path = try std.fmt.allocPrint(allocator, "{s}/things/{s}/history", .{ prefix, thing });
    defer allocator.free(history_path);
    var history = try client.call("GET", history_path, null, null, null, 200);
    defer history.deinit();
    const history_items = try path(&history.value, &.{ "data", "items" });
    try expect(arrayContainsStringField(history_items, "generation", history_generation), "retained history generation");

    const observations_path = try appendPath(allocator, prefix, "/observations");
    defer allocator.free(observations_path);
    var observations = try client.call("GET", observations_path, null, null, null, 200);
    defer observations.deinit();
    try expectArrayLength(try path(&observations.value, &.{ "data", "items" }), 1, "deduplicated observations");

    const capabilities_path = try appendPath(allocator, prefix, "/capabilities");
    defer allocator.free(capabilities_path);
    var capabilities = try client.call("GET", capabilities_path, null, null, null, 200);
    defer capabilities.deinit();
    try expectString(
        try path(&capabilities.value, &.{ "data", "runtime", "invokeaction" }),
        "unconfigured",
        "physical action state",
    );

    const privacy_path = try appendPath(allocator, prefix, "/privacy");
    defer allocator.free(privacy_path);
    var privacy = try client.call("GET", privacy_path, null, null, null, 200);
    defer privacy.deinit();
    try expectInteger(try path(&privacy.value, &.{ "data", "retained", "action_intents" }), 0, "retained action intents");

    var revoked = try client.call("GET", state_path, revoked_token, null, null, 401);
    defer revoked.deinit();
    try expectString(try path(&revoked.value, &.{ "error", "code" }), "unauthorized", "integrated revoked credential");

    std.debug.print(
        "NATIVE_INTEGRATED_PASS state=true property=true history=true duplicate_ingress=true " ++
            "revocation=true physical_actions=false\n",
        .{},
    );
}

const Origin = struct {
    address: IpAddress,
    authority: []const u8,
};

fn parseOrigin(origin: []const u8) !Origin {
    const scheme = "http://";
    if (!std.mem.startsWith(u8, origin, scheme)) return error.ExpectedPlainLoopbackOrigin;
    const authority = origin[scheme.len..];
    if (authority.len == 0 or std.mem.findScalar(u8, authority, '/') != null) return error.InvalidOrigin;
    const address = try IpAddress.parseLiteral(authority);
    const loopback = switch (address) {
        .ip4 => |ip4| ip4.bytes[0] == 127,
        .ip6 => |ip6| std.mem.eql(u8, &ip6.bytes, &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }),
    };
    if (!loopback or address.getPort() == 0) return error.ExpectedPlainLoopbackOrigin;
    return .{ .address = address, .authority = authority };
}

const Client = struct {
    allocator: Allocator,
    io: std.Io,
    address: IpAddress,
    authority: []const u8,
    token: []const u8,

    fn connect(self: Client) !Stream {
        // The origin is constrained to loopback, where connect either succeeds or
        // is refused locally. Zig's current threaded POSIX backend has not yet
        // implemented timed TCP connect, so response reads carry the hard timeout.
        return self.address.connect(self.io, .{ .mode = .stream });
    }

    fn send(
        self: Client,
        stream: *Stream,
        method: []const u8,
        request_path: []const u8,
        credential: ?[]const u8,
        body: ?[]const u8,
        operation: ?[]const u8,
        extra: ?Header,
    ) !void {
        try validateMethod(method);
        try validateRequestPath(request_path);
        const actual_credential = credential orelse self.token;
        try validateHeaderValue(actual_credential);
        if (operation) |value| try validateHeaderValue(value);
        if (extra) |header| {
            try validateHeaderName(header.name);
            try validateHeaderValue(header.value);
        }
        if (body) |bytes| if (bytes.len > response_limit) return error.RequestBodyTooLarge;

        var header_bytes: std.Io.Writer.Allocating = .init(self.allocator);
        defer header_bytes.deinit();
        const writer = &header_bytes.writer;
        const accept = if (std.mem.endsWith(u8, request_path, "/raw"))
            "application/vnd.wotex.tracker.observation+json"
        else if (std.mem.find(u8, request_path, "/events/stream") != null)
            "text/event-stream"
        else
            "application/json";
        try writer.print(
            "{s} {s} HTTP/1.1\r\nHost: {s}\r\nAccept: {s}\r\nAccept-Encoding: identity\r\nConnection: close\r\n",
            .{ method, request_path, self.authority, accept },
        );
        if (actual_credential.len != 0) try writer.print("Authorization: Bearer {s}\r\n", .{actual_credential});
        if (operation) |value| try writer.print("Idempotency-Key: {s}\r\n", .{value});
        if (extra) |header| try writer.print("{s}: {s}\r\n", .{ header.name, header.value });
        if (body) |bytes| try writer.print(
            "Content-Type: application/json\r\nContent-Length: {d}\r\n",
            .{bytes.len},
        );
        try writer.writeAll("\r\n");

        var network_buffer: [4096]u8 = undefined;
        var network_writer = stream.writer(self.io, &network_buffer);
        network_writer.interface.writeAll(header_bytes.written()) catch return network_writer.err orelse error.NetworkWriteFailed;
        if (body) |bytes| network_writer.interface.writeAll(bytes) catch return network_writer.err orelse error.NetworkWriteFailed;
        network_writer.interface.flush() catch return network_writer.err orelse error.NetworkWriteFailed;
    }

    fn call(
        self: Client,
        method: []const u8,
        request_path: []const u8,
        credential: ?[]const u8,
        body: ?[]const u8,
        operation: ?[]const u8,
        expected_status: u16,
    ) !JsonDocument {
        var stream = try self.connect();
        defer stream.close(self.io);
        try self.send(&stream, method, request_path, credential, body, operation, null);

        var response = ByteList.init(self.allocator);
        defer response.deinit();
        var chunk: [4096]u8 = undefined;
        while (true) {
            const message = stream.socket.receiveTimeout(self.io, &chunk, timeout) catch |err| switch (err) {
                error.ConnectionResetByPeer => {
                    if (try responseComplete(response.items)) break;
                    return error.IncompleteHttpResponse;
                },
                else => return err,
            };
            if (message.data.len == 0) break;
            if (response.items.len + message.data.len > response_limit + 8192) return error.HttpResponseTooLarge;
            try response.appendSlice(message.data);
            if (try responseComplete(response.items)) break;
        }

        const split = std.mem.find(u8, response.items, "\r\n\r\n") orelse return error.MissingHttpHeaders;
        const head = response.items[0..split];
        const status = try statusCode(head);
        if (status != expected_status) {
            std.debug.print(
                "{s} {s}: HTTP {d}, expected {d}: {s}\n",
                .{ method, request_path, status, expected_status, response.items[split + 4 ..] },
            );
            return error.UnexpectedHttpStatus;
        }
        const body_bytes = response.items[split + 4 ..];
        if (body_bytes.len > response_limit) return error.HttpBodyTooLarge;
        if (headerContains(head, "transfer-encoding", "chunked")) {
            const decoded = try decodeChunks(self.allocator, body_bytes);
            defer self.allocator.free(decoded);
            return parseJson(self.allocator, decoded);
        }
        return parseJson(self.allocator, body_bytes);
    }

    fn streamEvents(
        self: Client,
        request_path: []const u8,
        credential: []const u8,
        resume_cursor: ?[]const u8,
        count: usize,
    ) !EventList {
        var stream = try self.connect();
        defer stream.close(self.io);
        const extra: ?Header = if (resume_cursor) |cursor| .{ .name = "Last-Event-ID", .value = cursor } else null;
        try self.send(&stream, "GET", request_path, credential, null, null, extra);

        var wire = ByteList.init(self.allocator);
        defer wire.deinit();
        var decoded = ByteList.init(self.allocator);
        defer decoded.deinit();
        var events = EventList{};
        errdefer events.deinit(self.allocator);
        var headers_complete = false;
        var chunked = false;
        var received: usize = 0;
        var chunk: [4096]u8 = undefined;

        while (events.items.items.len < count) {
            const message = try stream.socket.receiveTimeout(self.io, &chunk, timeout);
            if (message.data.len == 0) return error.SseClosed;
            received += message.data.len;
            if (received > sse_limit) return error.SseLimitExceeded;
            try wire.appendSlice(message.data);

            if (!headers_complete) {
                if (std.mem.find(u8, wire.items, "\r\n\r\n")) |split| {
                    const head = wire.items[0..split];
                    if (try statusCode(head) != 200) return error.UnexpectedSseStatus;
                    chunked = headerContains(head, "transfer-encoding", "chunked");
                    try wire.replaceRange(0, split + 4, &.{});
                    headers_complete = true;
                }
            }
            if (!headers_complete) continue;
            if (chunked) {
                try drainChunks(&wire, &decoded);
            } else {
                try decoded.appendSlice(wire.items);
                wire.clearRetainingCapacity();
            }
            try drainEventFrames(self.allocator, &decoded, &events, count);
        }
        return events;
    }

    fn openReadyStream(
        self: Client,
        request_path: []const u8,
        credential: []const u8,
        cursor: []const u8,
    ) !Stream {
        var stream = try self.connect();
        errdefer stream.close(self.io);
        try self.send(
            &stream,
            "GET",
            request_path,
            credential,
            null,
            null,
            .{ .name = "Last-Event-ID", .value = cursor },
        );
        var bytes = ByteList.init(self.allocator);
        defer bytes.deinit();
        var chunk: [4096]u8 = undefined;
        while (std.mem.find(u8, bytes.items, "event: ready") == null) {
            const message = try stream.socket.receiveTimeout(self.io, &chunk, timeout);
            if (message.data.len == 0 or bytes.items.len + message.data.len > 32 * 1024) return error.SseNotReady;
            try bytes.appendSlice(message.data);
            if (std.mem.find(u8, bytes.items, "\r\n\r\n")) |split| {
                if (try statusCode(bytes.items[0..split]) != 200) return error.UnexpectedSseStatus;
            }
        }
        const split = std.mem.find(u8, bytes.items, "\r\n\r\n") orelse return error.MissingHttpHeaders;
        if (try statusCode(bytes.items[0..split]) != 200) return error.UnexpectedSseStatus;
        return stream;
    }
};

const Header = struct {
    name: []const u8,
    value: []const u8,
};

const Event = struct {
    id: []u8,
    cursor: []u8,
};

const EventList = struct {
    items: std.ArrayList(Event) = .empty,

    fn deinit(self: *EventList, allocator: Allocator) void {
        for (self.items.items) |event| {
            allocator.free(event.id);
            allocator.free(event.cursor);
        }
        self.items.deinit(allocator);
    }
};

fn drainEventFrames(allocator: Allocator, decoded: *ByteList, events: *EventList, count: usize) !void {
    while (events.items.items.len < count) {
        const separator = findFrameSeparator(decoded.items) orelse return;
        const frame = decoded.items[0..separator.index];
        if (frameHasEvent(frame, "tracker")) {
            const data = frameData(frame) orelse return error.MissingSseData;
            var document = try parseJson(allocator, data);
            defer document.deinit();
            const id = try allocator.dupe(u8, try stringValue(try field(&document.value, "id")));
            errdefer allocator.free(id);
            const cursor = try allocator.dupe(u8, try stringValue(try field(&document.value, "cursor")));
            errdefer allocator.free(cursor);
            try events.items.append(allocator, .{ .id = id, .cursor = cursor });
        }
        try decoded.replaceRange(0, separator.index + separator.length, &.{});
    }
}

const Separator = struct { index: usize, length: usize };

fn findFrameSeparator(bytes: []const u8) ?Separator {
    const lf = std.mem.find(u8, bytes, "\n\n");
    const crlf = std.mem.find(u8, bytes, "\r\n\r\n");
    if (lf == null) return if (crlf) |index_value| .{ .index = index_value, .length = 4 } else null;
    if (crlf == null or lf.? < crlf.?) return .{ .index = lf.?, .length = 2 };
    return .{ .index = crlf.?, .length = 4 };
}

fn frameHasEvent(frame: []const u8, expected: []const u8) bool {
    var lines = std.mem.splitScalar(u8, frame, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (std.mem.startsWith(u8, line, "event: ") and std.mem.eql(u8, line[7..], expected)) return true;
    }
    return false;
}

fn frameData(frame: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, frame, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (std.mem.startsWith(u8, line, "data: ")) return line[6..];
    }
    return null;
}

fn expectStreamClosed(io: std.Io, stream: *Stream) !void {
    var remaining: usize = sse_limit;
    var bytes: [4096]u8 = undefined;
    while (true) {
        const message = stream.socket.receiveTimeout(io, &bytes, timeout) catch |err| switch (err) {
            error.ConnectionResetByPeer => return,
            else => return err,
        };
        if (message.data.len == 0) return;
        remaining = std.math.sub(usize, remaining, message.data.len) catch return error.RevokedStreamDidNotClose;
    }
}

fn responseComplete(bytes: []const u8) !bool {
    const split = std.mem.find(u8, bytes, "\r\n\r\n") orelse return false;
    const head = bytes[0..split];
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            const length = try std.fmt.parseInt(usize, value, 10);
            if (length > response_limit) return error.HttpBodyTooLarge;
            return bytes.len >= split + 4 + length;
        }
    }
    return headerContains(head, "transfer-encoding", "chunked") and
        std.mem.endsWith(u8, bytes[split + 4 ..], "0\r\n\r\n");
}

fn statusCode(head: []const u8) !u16 {
    const line_end = std.mem.find(u8, head, "\r\n") orelse head.len;
    var parts = std.mem.splitScalar(u8, head[0..line_end], ' ');
    const version = parts.next() orelse return error.MissingHttpStatus;
    if (!std.mem.startsWith(u8, version, "HTTP/1.")) return error.InvalidHttpVersion;
    return std.fmt.parseInt(u16, parts.next() orelse return error.MissingHttpStatus, 10);
}

fn headerContains(head: []const u8, expected_name: []const u8, expected_value: []const u8) bool {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, expected_name) and
            std.ascii.indexOfIgnoreCase(value, expected_value) != null) return true;
    }
    return false;
}

fn decodeChunks(allocator: Allocator, input: []const u8) ![]u8 {
    var bytes = input;
    var result = ByteList.init(allocator);
    errdefer result.deinit();
    while (true) {
        const end = std.mem.find(u8, bytes, "\r\n") orelse return error.MissingChunkSize;
        const raw_size = bytes[0..end];
        const size_text = raw_size[0 .. std.mem.findScalar(u8, raw_size, ';') orelse raw_size.len];
        const size = try std.fmt.parseInt(usize, size_text, 16);
        bytes = bytes[end + 2 ..];
        if (size == 0) break;
        if (size > response_limit - result.items.len or bytes.len < size + 2 or
            !std.mem.eql(u8, bytes[size .. size + 2], "\r\n")) return error.InvalidChunk;
        try result.appendSlice(bytes[0..size]);
        bytes = bytes[size + 2 ..];
    }
    return result.toOwnedSlice();
}

fn drainChunks(wire: *ByteList, decoded: *ByteList) !void {
    while (true) {
        const end = std.mem.find(u8, wire.items, "\r\n") orelse return;
        const raw_size = wire.items[0..end];
        const size_text = raw_size[0 .. std.mem.findScalar(u8, raw_size, ';') orelse raw_size.len];
        const size = try std.fmt.parseInt(usize, size_text, 16);
        if (size == 0) return error.SseEnded;
        if (size > sse_limit or wire.items.len < end + 2 + size + 2) return;
        if (!std.mem.eql(u8, wire.items[end + 2 + size .. end + 4 + size], "\r\n")) return error.InvalidSseChunk;
        try decoded.appendSlice(wire.items[end + 2 .. end + 2 + size]);
        try wire.replaceRange(0, end + 4 + size, &.{});
    }
}

fn parseJson(allocator: Allocator, bytes: []const u8) !JsonDocument {
    if (bytes.len > response_limit) return error.JsonTooLarge;
    return std.json.parseFromSlice(Value, allocator, bytes, .{
        .allocate = .alloc_always,
        .max_value_len = response_limit,
    });
}

fn requiredString(value: *const Value, name: []const u8) ![]const u8 {
    return stringValue(try field(value, name));
}

fn optionalString(value: *const Value, name: []const u8) ?[]const u8 {
    const item = field(value, name) catch return null;
    return stringValue(item) catch null;
}

fn field(value: *const Value, name: []const u8) !*const Value {
    if (value.* != .object) return error.ExpectedJsonObject;
    return value.object.getPtr(name) orelse error.MissingJsonField;
}

fn path(value: *const Value, names: []const []const u8) !*const Value {
    var current = value;
    for (names) |name| current = try field(current, name);
    return current;
}

fn index(value: *const Value, item_index: usize, label: []const u8) !*const Value {
    if (value.* != .array or item_index >= value.array.items.len) {
        std.debug.print("assertion failed: {s}\n", .{label});
        return error.MissingJsonArrayItem;
    }
    return &value.array.items[item_index];
}

fn stringValue(value: *const Value) ![]const u8 {
    return switch (value.*) {
        .string => |string| string,
        else => error.ExpectedJsonString,
    };
}

fn expect(condition: bool, label: []const u8) !void {
    if (!condition) {
        std.debug.print("assertion failed: {s}\n", .{label});
        return error.AssertionFailed;
    }
}

fn expectString(value: *const Value, expected: []const u8, label: []const u8) !void {
    const actual = stringValue(value) catch {
        std.debug.print("assertion failed: {s} is not a string\n", .{label});
        return error.AssertionFailed;
    };
    if (!std.mem.eql(u8, actual, expected)) {
        std.debug.print("assertion failed: {s}: expected {s}, got {s}\n", .{ label, expected, actual });
        return error.AssertionFailed;
    }
}

fn expectStringSlice(actual: []const u8, expected: []const u8, label: []const u8) !void {
    if (!std.mem.eql(u8, actual, expected)) {
        std.debug.print("assertion failed: {s}: expected {s}, got {s}\n", .{ label, expected, actual });
        return error.AssertionFailed;
    }
}

fn expectInteger(value: *const Value, expected: i64, label: []const u8) !void {
    if (value.* != .integer or value.integer != expected) {
        std.debug.print("assertion failed: {s}: expected integer {d}\n", .{ label, expected });
        return error.AssertionFailed;
    }
}

fn expectNumber(value: *const Value, expected: f64, label: []const u8) !void {
    const actual: f64 = switch (value.*) {
        .integer => |number| @floatFromInt(number),
        .float => |number| number,
        else => {
            std.debug.print("assertion failed: {s} is not numeric\n", .{label});
            return error.AssertionFailed;
        },
    };
    if (actual != expected) {
        std.debug.print("assertion failed: {s}: expected {d}, got {d}\n", .{ label, expected, actual });
        return error.AssertionFailed;
    }
}

fn expectBool(value: *const Value, expected: bool, label: []const u8) !void {
    if (value.* != .bool or value.bool != expected) {
        std.debug.print("assertion failed: {s}: expected {}\n", .{ label, expected });
        return error.AssertionFailed;
    }
}

fn expectNull(value: *const Value, label: []const u8) !void {
    if (value.* != .null) {
        std.debug.print("assertion failed: {s}: expected null\n", .{label});
        return error.AssertionFailed;
    }
}

fn expectArrayLength(value: *const Value, expected: usize, label: []const u8) !void {
    if (value.* != .array or value.array.items.len != expected) {
        std.debug.print("assertion failed: {s}: expected {d} items\n", .{ label, expected });
        return error.AssertionFailed;
    }
}

fn arrayContainsStringField(value: *const Value, name: []const u8, expected: []const u8) bool {
    if (value.* != .array) return false;
    for (value.array.items) |*item| {
        const candidate = field(item, name) catch continue;
        const string = stringValue(candidate) catch continue;
        if (std.mem.eql(u8, string, expected)) return true;
    }
    return false;
}

fn jsonEqual(left: *const Value, right: *const Value) bool {
    if (std.meta.activeTag(left.*) != std.meta.activeTag(right.*)) return false;
    return switch (left.*) {
        .null => true,
        .bool => |value| value == right.bool,
        .integer => |value| value == right.integer,
        .float => |value| value == right.float,
        .number_string => |value| std.mem.eql(u8, value, right.number_string),
        .string => |value| std.mem.eql(u8, value, right.string),
        .array => |array| blk: {
            if (array.items.len != right.array.items.len) break :blk false;
            for (array.items, right.array.items) |*left_item, *right_item| {
                if (!jsonEqual(left_item, right_item)) break :blk false;
            }
            break :blk true;
        },
        .object => |object| blk: {
            if (object.count() != right.object.count()) break :blk false;
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                const right_value = right.object.getPtr(entry.key_ptr.*) orelse break :blk false;
                if (!jsonEqual(entry.value_ptr, right_value)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn appendPath(allocator: Allocator, prefix: []const u8, suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, suffix });
}

fn jsonObjectWithString(
    allocator: Allocator,
    key: []const u8,
    value: []const u8,
    suffix: []const u8,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"");
    try output.writer.writeAll(key);
    try output.writer.writeAll("\":");
    try std.json.Stringify.value(value, .{}, &output.writer);
    try output.writer.writeAll(suffix);
    try output.writer.writeByte('}');
    return output.toOwnedSlice();
}

fn makeQuery(allocator: Allocator, thing: []const u8, id: []const u8, to_at: i64, max_points: i64) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    try writer.writeAll("{\"aggregation\":\"last\",\"algorithm\":\"absolute-utc-buckets-v1\",\"bucket_ms\":1," ++
        "\"dataset\":\"measurements\",\"from_at\":1700000000000,\"id\":");
    try std.json.Stringify.value(id, .{}, writer);
    try writer.print(",\"max_points\":{d},\"measurement\":\"temperature\",\"missing_values\":\"excluded_and_disclosed\"," ++
        "\"order\":\"ascending\",\"qualities\":[\"valid\"],\"revision\":\"native-query-v1\"," ++
        "\"schema\":\"wtr.query-spec.v1\",\"series\":[", .{max_points});
    try std.json.Stringify.value(thing, .{}, writer);
    try writer.print("],\"timezone\":\"Etc/UTC\",\"to_at\":{d},\"unit\":\"Cel\"," ++
        "\"window_semantics\":\"from_inclusive_to_exclusive\"}}", .{to_at});
    return output.toOwnedSlice();
}

fn identifyQuery(allocator: Allocator, query: []const u8) ![]u8 {
    if (query.len == 0 or query[query.len - 1] != '}') return error.InvalidQuery;
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(query, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(
        allocator,
        "{s},\"identity\":\"wtr-json-v1:sha256:{s}\"}}",
        .{ query[0 .. query.len - 1], &hex },
    );
}

fn replaceIdentity(allocator: Allocator, query: []const u8, identity: []const u8) ![]u8 {
    const marker = "\"identity\":\"";
    const start = std.mem.find(u8, query, marker) orelse return error.MissingIdentity;
    const value_start = start + marker.len;
    const relative_end = std.mem.findScalar(u8, query[value_start..], '"') orelse return error.MissingIdentity;
    const value_end = value_start + relative_end;
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ query[0..value_start], identity, query[value_end..] });
}

fn makePageRequest(allocator: Allocator, query: []const u8, cursor: ?[]const u8, page_size: usize) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"schema\":\"wtr.query-page-request.v1\",\"query\":");
    try output.writer.writeAll(query);
    try output.writer.print(",\"page_size\":{d},\"cursor\":", .{page_size});
    if (cursor) |value| {
        try std.json.Stringify.value(value, .{}, &output.writer);
    } else {
        try output.writer.writeAll("null");
    }
    try output.writer.writeByte('}');
    return output.toOwnedSlice();
}

fn makeSavedQuery(allocator: Allocator, id: []const u8, query: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"id\":");
    try std.json.Stringify.value(id, .{}, &output.writer);
    try output.writer.writeAll(",\"title\":\"Native temperature\",\"query\":");
    try output.writer.writeAll(query);
    try output.writer.writeAll(",\"visualization\":{\"type\":\"line\",\"show_legend\":true,\"show_points\":false}," ++
        "\"expected_generation\":\"3\"}");
    return output.toOwnedSlice();
}

fn validateMethod(method: []const u8) !void {
    if (!std.mem.eql(u8, method, "GET") and !std.mem.eql(u8, method, "POST")) return error.InvalidHttpMethod;
}

fn validateRequestPath(request_path: []const u8) !void {
    if (request_path.len == 0 or request_path.len > 8192 or request_path[0] != '/' or
        std.mem.findAny(u8, request_path, "\r\n \t") != null) return error.InvalidRequestPath;
}

fn validateHeaderName(name: []const u8) !void {
    if (name.len == 0 or name.len > 128) return error.InvalidHeaderName;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-') return error.InvalidHeaderName;
}

fn validateHeaderValue(value: []const u8) !void {
    if (value.len > 8192 or std.mem.findAny(u8, value, "\r\n") != null) return error.InvalidHeaderValue;
}

fn validatePathComponent(value: []const u8) !void {
    if (value.len == 0 or value.len > 1024 or std.mem.findAny(u8, value, "/?#\r\n") != null) return error.InvalidPathComponent;
}

test "canonical query identity preserves 64-bit integers" {
    const allocator = std.testing.allocator;
    const base = try makeQuery(allocator, "urn:wotex:test", "native-temperature-history", 1_700_000_000_001, 1);
    defer allocator.free(base);
    try std.testing.expect(std.mem.find(u8, base, "\"from_at\":1700000000000") != null);
    try std.testing.expect(std.mem.find(u8, base, "\"aggregation\"").? < std.mem.find(u8, base, "\"algorithm\"").?);
    const identified = try identifyQuery(allocator, base);
    defer allocator.free(identified);
    try std.testing.expect(std.mem.find(u8, identified, "wtr-json-v1:sha256:") != null);
    var parsed = try parseJson(allocator, identified);
    defer parsed.deinit();
    try expectInteger(try field(&parsed.value, "from_at"), 1_700_000_000_000, "query from_at");
}

test "chunked responses decode extensions and retain exact bytes" {
    const decoded = try decodeChunks(std.testing.allocator, "4;fixture=yes\r\nwide\r\n6\r\n-value\r\n0\r\n\r\n");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("wide-value", decoded);
}

test "HTTP completion is bounded and length aware" {
    try std.testing.expect(!(try responseComplete("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nabc")));
    try std.testing.expect(try responseComplete("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nabcd"));
    try std.testing.expect(try responseComplete("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"));
}

test "SSE frames accept CRLF and LF delimiters" {
    try std.testing.expectEqual(@as(usize, 2), findFrameSeparator("event: tracker\n\nnext").?.length);
    try std.testing.expectEqual(@as(usize, 4), findFrameSeparator("event: tracker\r\n\r\nnext").?.length);
    try std.testing.expect(frameHasEvent("event: tracker\r\ndata: {}", "tracker"));
    try std.testing.expectEqualStrings("{}", frameData("event: tracker\r\ndata: {}").?);
}

test "origins and request metadata fail closed" {
    _ = try parseOrigin("http://127.0.0.1:4000");
    try std.testing.expectError(error.ExpectedPlainLoopbackOrigin, parseOrigin("https://127.0.0.1:4000"));
    try std.testing.expectError(error.ExpectedPlainLoopbackOrigin, parseOrigin("http://192.0.2.1:4000"));
    try std.testing.expectError(error.InvalidHeaderValue, validateHeaderValue("token\r\nInjected: yes"));
    try std.testing.expectError(error.InvalidRequestPath, validateRequestPath("/safe path"));
}
