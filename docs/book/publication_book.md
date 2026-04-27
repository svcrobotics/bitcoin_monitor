git status

git add docs/book/src/redis-stream.md

cd docs/book
mdbook build
cd ../..

git add docs/book
git commit -m "Chapter updated Redis Stream"

git push

git subtree push --prefix docs/book/book origin gh-pages