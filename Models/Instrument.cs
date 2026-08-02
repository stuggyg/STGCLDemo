using System;

namespace InstrumentSync.Models
{
    public class Instrument
    {
        public string SerialNo { get; set; }
        public string CPPartNo { get; set; }
        public string PPPartNo { get; set; }
        public string Desc { get; set; }
        public DateTime InputDate { get; set; }
    }
}
