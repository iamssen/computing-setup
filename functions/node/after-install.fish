# install-node가 기존 Node.js의 버전을 실제로 바꾼 뒤에 source하는 후처리.

# pm2 데몬은 이전 버전의 node로 떠 있으므로 새 버전으로 다시 띄운다.
if command -sq pm2
    pm2 update
    or return $status
end
