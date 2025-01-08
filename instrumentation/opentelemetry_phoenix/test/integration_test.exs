otp_vsn =
  :erlang.system_info(:otp_release)
  |> to_string()
  |> String.to_integer()

if otp_vsn >= 27 do
  defmodule OpentelemetryPhoenix.Integration.TracingTest do
    use ExUnit.Case, async: false
    import ExUnit.CaptureLog

    @moduletag :integration

    @adapters [:cowboy2, :bandit]

    defmodule TestController do
      use Phoenix.Controller,
        formats: [:html, :json]

      import Plug.Conn

      def root(conn, _params) do
        Plug.Conn.send_resp(conn, 200, "ok")
      end

      def hello(conn, _params) do
        Plug.Conn.send_resp(conn, 200, "ok")
        # %{"page" => "hello"} == params
      end

      def user(conn, _params) do
        Plug.Conn.send_resp(conn, 200, "ok")
      end

      def with_body(conn, _params) do
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"a" => "b"}))
      end

      def oops(_, _) do
        raise "oops"
      end

      def halted(conn, _params) do
        conn |> send_resp(500, "Internal Server Error") |> halt()
      end
    end

    defmodule Router do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn

      get "/", TestController, :root

      get "/hello", TestController, :hello

      get "/users/:user_id", TestController, :user

      get "/with_body", TestController, :with_body

      get "/router/oops", TestController, :oops

      get "/halted", TestController, :halted
    end

    for adapter <- @adapters do
      defmodule Module.concat(["#{String.capitalize(to_string(adapter))}Endpoint"]) do
        defmodule ErrorView do
          def render("404.json", %{kind: kind, reason: _reason, stack: _stack, conn: conn}) do
            %{error: "Got 404 from #{kind} with #{conn.method}"}
          end

          def render(template, %{conn: conn}) do
            unless conn.private.phoenix_endpoint do
              raise "no endpoint in error view"
            end

            "#{template} from Phoenix.ErrorView"
          end
        end

        use Phoenix.Endpoint, otp_app: :endpoint_int

        plug Plug.Telemetry, event_prefix: [:phoenix, adapter, :endpoint]

        plug Plug.Parsers,
          parsers: [:urlencoded, :multipart, :json],
          pass: ["*/*"],
          json_decoder: Phoenix.json_library()

        plug Plug.MethodOverride
        plug Plug.Head

        plug :oops
        plug Router

        @doc """
        Verify errors from the plug stack too (before the router).
        """
        def oops(conn, _opts) do
          if conn.path_info == ~w(oops) do
            raise "oops"
          else
            conn
          end
        end
      end
    end

    require OpenTelemetry.Span
    require Record

    for {name, spec} <- Record.extract_all(from_lib: "opentelemetry/include/otel_span.hrl") do
      Record.defrecord(name, spec)
    end

    for {name, spec} <-
          Record.extract_all(from_lib: "opentelemetry_api/include/opentelemetry.hrl") do
      Record.defrecord(name, spec)
    end

    alias OpenTelemetry.SemConv.ClientAttributes
    alias OpenTelemetry.SemConv.ErrorAttributes
    alias OpenTelemetry.SemConv.ExceptionAttributes
    alias OpenTelemetry.SemConv.NetworkAttributes
    alias OpenTelemetry.SemConv.ServerAttributes
    alias OpenTelemetry.SemConv.UserAgentAttributes
    alias OpenTelemetry.SemConv.Incubating.HTTPAttributes
    alias OpenTelemetry.SemConv.Incubating.URLAttributes

    setup context do
      :otel_simple_processor.set_exporter(:otel_exporter_pid, self())

      # Get unused port number
      {:ok, socket} = :gen_tcp.listen(0, [])
      {:ok, port} = :inet.port(socket)
      :gen_tcp.close(socket)

      setup_adapter(Map.put(context, :port, port))

      {:ok, port: port}
    end

    defp setup_adapter(%{adapter: :bandit, port: port} = context) do
      {:ok, _} =
        start_supervised({
          BanditEndpoint,
          http: [port: port],
          url: [host: "bandit-example.com"],
          adapter: Bandit.PhoenixAdapter,
          server: true,
          drainer: false,
          render_errors: [accepts: ~w(html json)]
        })

      OpentelemetryBandit.setup(Map.get(context, :opts, []))

      OpentelemetryPhoenix.setup(
        adapter: :bandit,
        endpoint_prefix: [:phoenix, :bandit, :endpoint]
      )

      on_exit(fn ->
        [
          :telemetry.list_handlers([:phoenix]),
          :telemetry.list_handlers([:bandit])
        ]
        |> List.flatten()
        |> Enum.each(&:telemetry.detach(&1.id))
      end)
    end

    defp setup_adapter(%{adapter: :cowboy2, port: port} = context) do
      {:ok, _} =
        start_supervised({
          Cowboy2Endpoint,
          http: [port: port],
          url: [host: "cowboy-example.com"],
          adapter: Phoenix.Endpoint.Cowboy2Adapter,
          server: true,
          drainer: false,
          render_errors: [accepts: ~w(html json)]
        })

      :opentelemetry_cowboy.setup(Map.get(context, :opts, []))

      OpentelemetryPhoenix.setup(
        adapter: :cowboy2,
        endpoint_prefix: [:phoenix, :cowboy2, :endpoint]
      )

      on_exit(fn ->
        [
          :telemetry.list_handlers([:phoenix]),
          :telemetry.list_handlers([:cowboy])
        ]
        |> List.flatten()
        |> Enum.each(&:telemetry.detach(&1.id))
      end)
    end

    adapter_suites =
      for adapter <- [:bandit, :cowboy2], protocol <- [:http1, :http2], do: {adapter, protocol}

    for {adapter, protocol} <- adapter_suites do
      describe "#{adapter} - #{protocol}" do
        @describetag adapter: adapter, protocol: protocol

        test "basic request with default options", %{protocol: protocol} = context do
          capture_log(fn ->
            request!(
              context,
              "/users/1234",
              params: [a: 1, b: "abc"],
              headers: %{
                "traceparent" => "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
                "tracestate" => "congo=t61rcWkgMzE"
              }
            )

            assert_receive {:span,
                            span(
                              name: "GET /users/:user_id",
                              kind: :server,
                              attributes: span_attrs,
                              parent_span_id: 13_235_353_014_750_950_193
                            )}

            attrs = :otel_attributes.map(span_attrs)

            expected_proto = if protocol == :http1, do: :"1.1", else: :"2"

            expected_attrs = [
              {ClientAttributes.client_address(), "127.0.0.1"},
              {HTTPAttributes.http_request_method(), :GET},
              {HTTPAttributes.http_response_status_code(), 200},
              {NetworkAttributes.network_peer_address(), "127.0.0.1"},
              {NetworkAttributes.network_protocol_version(), expected_proto},
              {URLAttributes.url_path(), "/users/1234"},
              {URLAttributes.url_query(), "a=1&b=abc"},
              {URLAttributes.url_scheme(), :http},
              {HTTPAttributes.http_route(), "/users/:user_id"},
              {:"phoenix.action", :user},
              {:"phoenix.plug", OpentelemetryPhoenix.Integration.TracingTest.TestController}
            ]

            for {attr, val} <- expected_attrs do
              assert Map.get(attrs, attr) == val
            end

            user_agent = Map.get(attrs, UserAgentAttributes.user_agent_original())
            assert String.starts_with?(user_agent, "req/")
            assert OpenTelemetry.Tracer.current_span_ctx() == :undefined
          end)
        end

        @tag opts: [public_endpoint: true]
        test "public endpoint true", context do
          capture_log(fn ->
            request!(
              context,
              "/hello",
              headers: %{
                "traceparent" => "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
                "tracestate" => "congo=t61rcWkgMzE"
              }
            )

            refute_receive {:span,
                            span(
                              name: "GET /hello",
                              kind: :server,
                              parent_span_id: 13_235_353_014_750_950_193
                            )}

            assert_receive {:span,
                            span(
                              name: "GET /hello",
                              kind: :server,
                              links: links,
                              parent_span_id: :undefined
                            )}

            assert length(:otel_links.list(links)) == 1
          end)
        end

        @tag opts: [public_endpoint_fn: {__MODULE__, :public_endpoint_fn, []}]
        test "public endpoint fn", context do
          capture_log(fn ->
            System.put_env("TENANT", "customer")

            request!(
              context,
              "/hello",
              headers: %{
                "traceparent" => "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
                "tracestate" => "congo=t61rcWkgMzE"
              }
            )

            refute_receive {:span,
                            span(
                              name: "GET /hello",
                              kind: :server,
                              parent_span_id: 13_235_353_014_750_950_193
                            )}

            assert_receive {:span,
                            span(
                              name: "GET /hello",
                              kind: :server,
                              links: links,
                              parent_span_id: :undefined
                            )}

            assert length(:otel_links.list(links)) == 1

            System.put_env("TENANT", "internal")

            request!(
              context,
              "/hello",
              headers: %{
                "traceparent" => "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
                "tracestate" => "congo=t61rcWkgMzE"
              }
            )

            assert_receive {:span,
                            span(
                              name: "GET /hello",
                              kind: :server,
                              parent_span_id: 13_235_353_014_750_950_193
                            )}

            refute_receive {:span,
                            span(
                              name: "GET /hello",
                              kind: :server,
                              parent_span_id: :undefined
                            )}

            System.delete_env("PUBLIC")
          end)
        end

        @tag opts: [
               opt_in_attrs: [
                 ClientAttributes.client_port(),
                 HTTPAttributes.http_request_body_size(),
                 HTTPAttributes.http_response_body_size(),
                 NetworkAttributes.network_local_address(),
                 NetworkAttributes.network_local_port(),
                 NetworkAttributes.network_transport()
               ],
               request_headers: ["test-header"],
               response_headers: ["content-type"]
             ]
        test "with all opt-ins", %{port: port} = context do
          capture_log(fn ->
            request!(
              context,
              "/with_body",
              headers: %{"test-header" => "request header"}
            )

            assert_receive {:span,
                            span(
                              name: "GET /with_body",
                              attributes: span_attrs
                            )}

            attrs = :otel_attributes.map(span_attrs)

            expected_attrs = [
              {ClientAttributes.client_address(), "127.0.0.1"},
              {HTTPAttributes.http_request_body_size(), 0},
              {HTTPAttributes.http_request_method(), :GET},
              {HTTPAttributes.http_response_status_code(), 200},
              {String.to_atom("#{HTTPAttributes.http_request_header()}.test-header"), ["request header"]},
              {String.to_atom("#{HTTPAttributes.http_response_header()}.content-type"),
               ["application/json; charset=utf-8"]},
              {NetworkAttributes.network_local_address(), "localhost"},
              {NetworkAttributes.network_local_port(), port},
              {NetworkAttributes.network_peer_address(), "127.0.0.1"},
              {URLAttributes.url_path(), "/with_body"},
              {URLAttributes.url_scheme(), :http}
            ]

            for {attr, expected} <- expected_attrs do
              actual = Map.get(attrs, attr)
              assert expected == actual, "#{attr} expected #{expected} got #{actual}"
            end

            user_agent = Map.get(attrs, UserAgentAttributes.user_agent_original())
            assert String.starts_with?(user_agent, "req/")

            client_port = Map.get(attrs, ClientAttributes.client_port())
            assert is_integer(client_port)

            body_size = Map.get(attrs, HTTPAttributes.http_response_body_size())
            # for some reason bandit and cowboy2 measure this differently with
            # bandit being much larger despite the bodies being the same and compression
            # not being enabled
            assert is_integer(body_size) && body_size > 0
          end)
        end

        @tag opts: [
               client_address_headers: ["x-forwarded-for", "custom-client"],
               client_headers_sort_fn: &__MODULE__.custom_client_header_sort/2,
               scheme_headers: ["custom-scheme", "x-forwarded-proto"],
               scheme_headers_sort_fn: &__MODULE__.custom_scheme_header_sort/2,
               server_address_headers: ["custom-host", "forwarded", "host"],
               server_headers_sort_fn: &__MODULE__.custom_server_header_sort/2
             ]
        test "with custom header settings", context do
          capture_log(fn ->
            request!(
              context,
              "/hello",
              headers: %{
                "forwarded" =>
                  ~S(host=developer.mozilla.org:4321; for=192.0.2.60, for="[2001:db8:cafe::17]";proto=http;by=203.0.113.43),
                "x-forwarded-proto" => "http",
                "custom-scheme" => "https",
                "custom-client" => "23.23.23.23",
                "traceparent" => "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
                "tracestate" => "congo=t61rcWkgMzE"
              }
            )

            assert_receive {:span,
                            span(
                              name: "GET /hello",
                              kind: :server,
                              attributes: span_attrs
                            )}

            attrs = :otel_attributes.map(span_attrs)

            expected_attrs = [
              {ClientAttributes.client_address(), "23.23.23.23"},
              {HTTPAttributes.http_request_method(), :GET},
              {HTTPAttributes.http_response_status_code(), 200},
              {NetworkAttributes.network_peer_address(), "127.0.0.1"},
              {ServerAttributes.server_address(), "developer.mozilla.org"},
              {ServerAttributes.server_port(), 4321},
              {URLAttributes.url_scheme(), :https}
            ]

            for {attr, val} <- expected_attrs do
              assert Map.get(attrs, attr) == val
            end

            user_agent = Map.get(attrs, UserAgentAttributes.user_agent_original())
            assert String.starts_with?(user_agent, "req/")
          end)
        end

        test "with missing user-agent", %{port: port} do
          capture_log(fn ->
            {:ok, {{_, 200, _}, _, _}} =
              :httpc.request(
                :get,
                {~c"http://localhost:#{port}/hello", []},
                [],
                []
              )

            assert_receive {:span, span(attributes: span_attrs)}

            attrs = :otel_attributes.map(span_attrs)

            assert Map.get(attrs, UserAgentAttributes.user_agent_original()) == ""
          end)
        end

        test "with exception", context do
          capture_log(fn ->
            request!(context, "/router/oops")

            expected_status = OpenTelemetry.status(:error, "")

            assert_receive {:span,
                            span(
                              name: "GET /router/oops",
                              attributes: span_attrs,
                              events: events,
                              status: ^expected_status
                            )}

            attrs = :otel_attributes.map(span_attrs)

            expected_attrs = [
              {ClientAttributes.client_address(), "127.0.0.1"},
              {ErrorAttributes.error_type(), RuntimeError},
              {HTTPAttributes.http_request_method(), :GET},
              {HTTPAttributes.http_response_status_code(), 500},
              {NetworkAttributes.network_peer_address(), "127.0.0.1"},
              {URLAttributes.url_path(), "/router/oops"},
              {URLAttributes.url_scheme(), :http}
            ]

            for {attr, expected} <- expected_attrs do
              actual = Map.get(attrs, attr)
              assert actual == expected, " expected #{attr} to equal #{expected}, got #{actual}"
            end

            [
              event(
                name: :exception,
                attributes: event_attributes
              )
            ] = :otel_events.list(events)

            assert [
                     ExceptionAttributes.exception_message(),
                     ExceptionAttributes.exception_stacktrace(),
                     ExceptionAttributes.exception_type()
                   ] ==
                     Enum.sort(Map.keys(:otel_attributes.map(event_attributes))),
                   "exception attributes"
          end)
        end

        test "with halted request", context do
          capture_log(fn ->
            request!(context, "/halted")

            expected_status = OpenTelemetry.status(:error, "")

            assert_receive {:span,
                            span(
                              name: "GET /halted",
                              kind: :server,
                              attributes: span_attrs,
                              status: ^expected_status
                            )}

            attrs = :otel_attributes.map(span_attrs)

            expected_attrs = [
              {ErrorAttributes.error_type(), "500"},
              {HTTPAttributes.http_response_status_code(), 500},
              {URLAttributes.url_scheme(), :http}
            ]

            for {attr, val} <- expected_attrs do
              assert Map.get(attrs, attr) == val, " expected #{attr} to equal #{val}"
            end
          end)
        end
      end
    end

    defp request!(%{port: port, protocol: protocol}, "/" <> uri, opts \\ []) do
      [
        url: "http://localhost:#{port}/#{uri}",
        retry: false,
        connect_options: [protocols: [protocol]]
      ]
      |> Keyword.merge(opts)
      |> Req.new()
      |> Req.get!()
    end

    def custom_client_header_sort(h1, h2) do
      h1_priority = custom_client_header_priority(h1)
      h2_priority = custom_client_header_priority(h2)

      case {h1_priority, h2_priority} do
        {h1, h2} when h1 <= h2 ->
          true

        {h1, h2} when h1 > h2 ->
          false
      end
    end

    defp custom_client_header_priority({header_name, _value}) do
      case header_name do
        "custom-client" -> 1
        "x-forwarded-for" -> 2
      end
    end

    def custom_server_header_sort(h1, h2) do
      h1_priority = custom_server_header_priority(h1)
      h2_priority = custom_server_header_priority(h2)

      case {h1_priority, h2_priority} do
        {h1, h2} when h1 <= h2 ->
          true

        {h1, h2} when h1 > h2 ->
          false
      end
    end

    defp custom_server_header_priority({header_name, _value}) do
      case header_name do
        "custom-host" -> 1
        "x-forwarded-host" -> 2
        "forwarded" -> 3
        _ -> 4
      end
    end

    def custom_scheme_header_sort(h1, h2) do
      h1_priority = custom_scheme_header_priority(h1)
      h2_priority = custom_scheme_header_priority(h2)

      case {h1_priority, h2_priority} do
        {h1, h2} when h1 <= h2 ->
          true

        {h1, h2} when h1 > h2 ->
          false
      end
    end

    defp custom_scheme_header_priority({header_name, _value}) do
      case header_name do
        "custom-scheme" -> 1
        "x-forwarded-proto" -> 2
      end
    end

    def public_endpoint_fn(_conn, _opts) do
      System.get_env("TENANT") != "internal"
    end
  end
end
