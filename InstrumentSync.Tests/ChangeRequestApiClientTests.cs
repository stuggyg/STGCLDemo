using System;
using System.Net.Http;
using System.Threading.Tasks;
using InstrumentSync;
using InstrumentSync.Models;
using Xunit;

namespace InstrumentSync.Tests
{
    public class ChangeRequestApiClientTests
    {
        // Validation is checked before any request is sent, so a real network
        // connection is never attempted by these tests.
        private static readonly HttpClient UnusedHttpClient =
            new HttpClient { BaseAddress = new Uri("https://test.local/") };

        [Fact]
        public async Task InsertChangeRequestAsync_ThrowsOnNullInstrument()
        {
            var client = new ChangeRequestApiClient(UnusedHttpClient);

            await Assert.ThrowsAsync<ArgumentNullException>(
                () => client.InsertChangeRequestAsync(null));
        }

        [Theory]
        [InlineData(null)]
        [InlineData("")]
        [InlineData("   ")]
        public async Task InsertChangeRequestAsync_ReturnsFalseWhenSerialNoIsMissing(string serialNo)
        {
            var client = new ChangeRequestApiClient(UnusedHttpClient);
            var instrument = new Instrument
            {
                SerialNo = serialNo,
                CPPartNo = "CP-1001",
                PPPartNo = "PP-2001",
                Desc = "Test",
                InputDate = DateTime.UtcNow
            };

            var result = await client.InsertChangeRequestAsync(instrument);

            Assert.False(result);
        }
    }
}
