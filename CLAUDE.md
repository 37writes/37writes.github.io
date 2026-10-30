# tech-blog

<!-- 37writes-kit:profile:start -->
## Project Profile (37writes-kit)
- **구분**: 개인
- **설명**: 개인 기술 블로그 https://37writes.github.io/ (Jekyll + jekyll-theme-chirpy 7.6.0)
- **스택**: Ruby (Homebrew), Jekyll 4, jekyll-theme-chirpy gem, Dart Sass(sass-embedded)
- **빌드**: `PATH=/opt/homebrew/opt/ruby/bin:$PATH BUNDLE_PATH=vendor/bundle JEKYLL_ENV=production bundle exec jekyll b`
- **테스트**: `bundle exec htmlproofer _site --disable-external --ignore-urls "/^http:\/\/127.0.0.1/,/^http:\/\/0.0.0.0/,/^http:\/\/localhost/"` 그리고 `sh tools/design-check.sh`
- **실행**: `bundle exec jekyll s`
- **배포**: GitHub Actions "Build and Deploy" (main push → 빌드·htmlproofer → GitHub Pages)
- **push**: 배포 (main push 시 자동 배포)
- **원격**: GitHub `37writes/37writes.github.io`
- **절차**: 커밋 형식 `type(scope): 한국어 요약`(commit-msg 훅). 작업 절차·승인·검증·기록은 /kit:harness
<!-- 37writes-kit:profile:end -->

## 디자인
화면을 바꾸기 전에 `docs/design-system.md`(디자인 프로필)를 읽는다. 색·글꼴·반경은 `--kit-*` 토큰만 쓰고 `_sass/kit/` 원본은 고치지 않는다.
