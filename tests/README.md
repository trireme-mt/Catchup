# Tests

These run the addon outside the game against a small fake WoW API
(`harness.lua`), simulating several party members talking to each other.
They need Lua 5.1 (the version WoW uses).

    cd tests
    lua5.1 test.lua ..
    lua5.1 test_secret.lua ..

They check logic only; the real client is the real test.
