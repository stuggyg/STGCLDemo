using System;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using InstrumentSync;
using InstrumentSync.Models;
using Xunit;

namespace InstrumentSync.Tests
{
    /// <summary>
    /// These tests exercise ChangeRequestApiClient through a real HttpClient pipeline
    /// (serialization, request construction, response handling) against a fake
    /// HttpMessageHandler instead of the real network - verifying the integration
    /// between the client and HttpClient, not just its internal decision logic.
    /// </summary>
    public class ChangeRequestApiClientIntegrationTests
    {
        private class FakeHttpMessageHandler : HttpMessageHandler
        {
            private readonly HttpStatusCode? _statusCode;
            private readonly Exception? _exceptionToThrow;

            public HttpRequestMessage? LastRequest { get; private set; }
            public string? LastRequestBody { get; private set; }

            public FakeHttpMessageHandler(HttpStatusCode statusCode)
            {
                _statusCode = statusCode;
            }

            public FakeHttpMessageHandler(Exception exceptionToThrow)
            {
                _exceptionToThrow = exceptionToThrow;
            }

            protected override async Task<HttpResponseMessage> SendAsync(
                HttpRequestMessage request, CancellationToken cancellationToken)
            {
                LastRequest = request;
                LastRequestBody = request.Content is null
                    ? null
                    : await request.Content.ReadAsStringAsync(cancellationToken);

                if (_exceptionToThrow is not null)
                {
                    throw _exceptionToThrow;
                }

                return new HttpResponseMessage(_statusCode!.Value);
            }
        }

        private static ChangeRequestApiClient CreateClient(FakeHttpMessageHandler handler)
        {
            var httpClient = new HttpClient(handler) { BaseAddress = new Uri("https://test.local/") };
            return new ChangeRequestApiClient(httpClient);
        }

        [Fact]
        public async Task InsertChangeRequestAsync_SendsExpectedRequestAndReturnsTrueOnSuccess()
        {
            var handler = new FakeHttpMessageHandler(HttpStatusCode.OK);
            var client = CreateClient(handler);
            var instrument = new Instrument
            {
                SerialNo = "SN-0001",
                CPPartNo = "CP-1001",
                PPPartNo = "PP-2001",
                Desc = "Test Instrument",
                InputDate = new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc)
            };

            var result = await client.InsertChangeRequestAsync(instrument);

            Assert.True(result);
            Assert.NotNull(handler.LastRequest);
            Assert.Equal(HttpMethod.Post, handler.LastRequest!.Method);
            Assert.Equal("https://test.local/api/InsertChangeRequest", handler.LastRequest.RequestUri!.ToString());
            Assert.Contains("\"SerialNo\":\"SN-0001\"", handler.LastRequestBody);
            Assert.Contains("\"CPPartNo\":\"CP-1001\"", handler.LastRequestBody);
        }

        [Fact]
        public async Task InsertChangeRequestAsync_ReturnsFalseOnNonSuccessStatusCode()
        {
            var handler = new FakeHttpMessageHandler(HttpStatusCode.InternalServerError);
            var client = CreateClient(handler);
            var instrument = new Instrument { SerialNo = "SN-0002" };

            var result = await client.InsertChangeRequestAsync(instrument);

            Assert.False(result);
        }

        [Fact]
        public async Task InsertChangeRequestAsync_ReturnsFalseWhenTransportThrows()
        {
            var handler = new FakeHttpMessageHandler(new HttpRequestException("connection refused"));
            var client = CreateClient(handler);
            var instrument = new Instrument { SerialNo = "SN-0003" };

            var result = await client.InsertChangeRequestAsync(instrument);

            Assert.False(result);
        }

        [Fact]
        public async Task InsertChangeRequestAsync_ReturnsFalseWhenRequestTimesOut()
        {
            var handler = new FakeHttpMessageHandler(new TaskCanceledException("request timed out"));
            var client = CreateClient(handler);
            var instrument = new Instrument { SerialNo = "SN-0004" };

            var result = await client.InsertChangeRequestAsync(instrument);

            Assert.False(result);
        }
    }
}
