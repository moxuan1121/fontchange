cd 'c:\Users\Zhao WenYi\Desktop\sit\fontchange'

Write-Host "Current directory: $(Get-Location)"
Write-Host ""
Write-Host "Git status:"
git status --short

Write-Host ""
Write-Host "Git log (last 3 commits):"
git log --oneline -3

Write-Host ""
Write-Host "Checking for uncommitted changes..."
$status = git status --porcelain
if ([string]::IsNullOrEmpty($status)) {
    Write-Host "No uncommitted changes"
} else {
    Write-Host "Uncommitted changes found:"
    Write-Host $status
    Write-Host ""
    Write-Host "Adding and committing..."
    git add -A
    git commit -m "Refactor font key detection to use individual if statements"
    Write-Host ""
    Write-Host "Pushing to remote..."
    git push origin fix/orphan-import-cleanup
    Write-Host ""
    Write-Host "Push completed"
}

Write-Host ""
Write-Host "Latest remote commit:"
git ls-remote origin fix/orphan-import-cleanup | Select-Object -First 1

Write-Host ""
Write-Host "Triggering new build..."
gh workflow run build.yml --ref fix/orphan-import-cleanup

Write-Host ""
Write-Host "All done!"
