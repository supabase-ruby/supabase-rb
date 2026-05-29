# Contributing

We highly appreciate feedback and contributions from the community! If you'd like to contribute to this project, please make sure to review and follow the guidelines below.

## Code of conduct

In the interest of fostering an open and welcoming environment, please review and follow our [code of conduct](./CODE_OF_CONDUCT.md).

## Code and copy reviews

All submissions, including submissions by project members, require review. We use GitHub pull requests for this purpose. After filing a pull request, please tag any two of the [current maintainers](./MAINTAINERS.md) to request a review.

## Report an issue / file a feature request

Before opening a new issue or request, please take a moment to check the existing issues and discussions to see if your topic has already been addressed. This helps us avoid duplicate issues and keeps the conversation focused.

Report all issues and file all feature requests through [GitHub Issues](https://github.com/supabase-community/supabase-rb/issues).

## Create a pull request

When making pull requests to the repository, follow these guidelines for both bug fixes and new features:

- Before creating a pull request, file a GitHub Issue so that maintainers and the community can discuss the problem and potential solutions before you spend time on an implementation.
- In your PR's description, link to any related issues or pull requests to give reviewers the full context of your change. Use `#` followed by the issue or PR number (e.g. `#123`).
- For commit messages, follow the [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) format. For example:
  - `feat(storage): add analytics bucket client`
  - `fix(postgrest): handle empty maybe_single response`
  - `docs(auth): clarify MFA flow ordering`

## Local development

The Ruby port ships as a single `supabase-rb` gem. Each subdirectory under `lib/supabase/` corresponds to one Python `src/<module>/` from `supabase-py`.

```sh
bundle install
bundle exec rspec
bundle exec rubocop
```

When porting a new feature from `supabase-py`, prefer mirroring the Python file layout under `lib/supabase/<module>/` and adding a matching spec under `spec/supabase/<module>/`. The single `supabase-rb.gemspec` packages every module, so changes anywhere under `lib/supabase/` ship together.
