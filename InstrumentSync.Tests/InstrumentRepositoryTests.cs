using System.Linq;
using InstrumentSync.DAL;
using Xunit;

namespace InstrumentSync.Tests
{
    public class InstrumentRepositoryTests
    {
        [Fact]
        public void GetFakeInstruments_ReturnsRequestedCount()
        {
            var repository = new InstrumentRepository("test-connection-string");

            var instruments = repository.GetFakeInstruments(10);

            Assert.Equal(10, instruments.Count);
        }

        [Fact]
        public void GetFakeInstruments_DefaultsToTwentyFive()
        {
            var repository = new InstrumentRepository("test-connection-string");

            var instruments = repository.GetFakeInstruments();

            Assert.Equal(25, instruments.Count);
        }

        [Fact]
        public void GetFakeInstruments_GeneratesExpectedFieldsForFirstRecord()
        {
            var repository = new InstrumentRepository("test-connection-string");

            var first = repository.GetFakeInstruments(1).Single();

            Assert.Equal("SN-0001", first.SerialNo);
            Assert.Equal("CP-1001", first.CPPartNo);
            Assert.Equal("PP-2001", first.PPPartNo);
            Assert.Equal("Test Instrument 1", first.Desc);
        }

        [Fact]
        public void GetFakeInstruments_SerialNumbersAreUnique()
        {
            var repository = new InstrumentRepository("test-connection-string");

            var instruments = repository.GetFakeInstruments(25);

            Assert.Equal(instruments.Count, instruments.Select(i => i.SerialNo).Distinct().Count());
        }
    }
}
