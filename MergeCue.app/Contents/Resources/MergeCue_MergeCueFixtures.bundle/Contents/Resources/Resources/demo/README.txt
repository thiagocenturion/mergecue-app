MergeCue demo mode (synthetic data, never live).

Demo mode serves the provider-native fixtures under ../github, ../gitlab and ../bitbucket through the real
adapters (DemoScenario / DemoScenarioTransport) and generates a small synthetic acme/payments-api git repository
at runtime (DemoRepository / DemoRepositoryFiles.swift) so tasks get real isolated worktrees.
