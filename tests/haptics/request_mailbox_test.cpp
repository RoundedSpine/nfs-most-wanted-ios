#include "../../kit/host/sdl/haptic_request_mailbox.h"
#include <cassert>
#include <atomic>
#include <thread>
#include <vector>
#include <iostream>
int main(){
 HapticRequestMailbox m;
 auto initial=m.latest();assert(initial.version==0&&initial.intensity==0);
 auto a=m.publish(100,200);assert(m.current(a)&&a.intensity==200);
 auto b=m.publish(0,0);assert(!m.current(a)&&m.current(b)&&b.intensity==0);
 for(int i=0;i<10000;++i)m.publish(i%65536,(i*3)%65536);
 auto before=m.latest();
 constexpr int N=8,K=20000;
 std::vector<std::thread> threads;
 std::atomic<bool> go{false};
 for(int i=0;i<N;++i)threads.emplace_back([&,i]{
  while(!go.load(std::memory_order_acquire))std::this_thread::yield();
  for(int j=0;j<K;++j){
   auto r=m.publish(static_cast<uint16_t>(i*100+j),static_cast<uint16_t>(i*100+j+1));
   assert(r.intensity==static_cast<uint16_t>(i*100+j+1));
  }
 });
 go.store(true,std::memory_order_release);
 for(auto &th:threads)th.join();
 assert(m.latest().version==before.version+N*K);
 auto stop=m.publish(0,0);assert(m.current(stop)&&m.latest().intensity==0);
 std::cout<<"PASS atomic production mailbox: 160000 concurrent publications, version consistency, final stop\n";
}
