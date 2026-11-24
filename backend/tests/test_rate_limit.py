import unittest

from app.rate_limit import FixedWindowRateLimiter


class FixedWindowRateLimiterTests(unittest.TestCase):
    def test_rejects_after_limit_and_returns_retry_time(self):
        limiter = FixedWindowRateLimiter()
        self.assertEqual(
            limiter.consume("login:email:person@example.com", limit=2, window_seconds=60, now=100),
            (True, 0),
        )
        self.assertEqual(
            limiter.consume("login:email:person@example.com", limit=2, window_seconds=60, now=101),
            (True, 0),
        )
        self.assertEqual(
            limiter.consume("login:email:person@example.com", limit=2, window_seconds=60, now=102),
            (False, 58),
        )

    def test_allows_requests_after_window_expires(self):
        limiter = FixedWindowRateLimiter()
        limiter.consume("signup:ip:127.0.0.1", limit=1, window_seconds=10, now=5)
        self.assertEqual(
            limiter.consume("signup:ip:127.0.0.1", limit=1, window_seconds=10, now=15),
            (True, 0),
        )

    def test_limits_memory_growth_from_many_client_keys(self):
        limiter = FixedWindowRateLimiter(max_keys=2)
        limiter.consume("a", limit=1, window_seconds=10, now=0)
        limiter.consume("b", limit=1, window_seconds=10, now=0)
        limiter.consume("c", limit=1, window_seconds=10, now=0)
        self.assertLessEqual(len(limiter._windows), 2)


if __name__ == "__main__":
    unittest.main()
