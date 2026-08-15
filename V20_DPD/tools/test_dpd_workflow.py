import pathlib
import sys
import unittest

import numpy as np

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import dpd_workflow as dpd


class DpdWorkflowTest(unittest.TestCase):
    def test_pack_round_trip(self):
        original = 0.25 - 0.5j
        decoded = dpd.unpack_iq(dpd.pack_iq(original))
        self.assertAlmostEqual(decoded.real, original.real, places=4)
        self.assertAlmostEqual(decoded.imag, original.imag, places=4)

    def test_identity_lut(self):
        coefficients = np.zeros(16, dtype=complex)
        coefficients[0] = 1.0
        model = {"coefficients": coefficients, "taps": 4, "orders": (1, 3, 5, 7)}
        luts = dpd.coefficients_to_luts(model)
        self.assertTrue(np.all(luts[0] == 0x00004000))
        self.assertTrue(np.all(luts[1:] == 0))

    def test_synthetic_closed_loop(self):
        result = dpd.run_selftest()
        self.assertGreater(result["improvement_db"], 1.0)

    def test_acpr(self):
        sample_rate = 100e6
        time = np.arange(4096) / sample_rate
        signal = np.exp(2j * np.pi * 1e6 * time) + 0.1 * np.exp(2j * np.pi * 21e6 * time)
        result = dpd.acpr_db(signal, sample_rate, 4e6, 20e6)
        self.assertLess(result["upper_acpr_db"], -15.0)


if __name__ == "__main__":
    unittest.main()
