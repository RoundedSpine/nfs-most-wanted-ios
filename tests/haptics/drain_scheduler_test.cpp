#include "../../kit/host/sdl/haptic_drain_scheduler.h"
#include <atomic>
#include <cassert>
#include <thread>
#include <vector>
#include <iostream>
int main(){
 HapticDrainScheduler s;
 assert(s.publish(100,0));
 assert(!s.publish(200,0));
 auto a=s.latest();assert(a.intensity==200);
 assert(!s.next(a));
 assert(s.publish(0,0));
 auto stop=s.latest();assert(stop.intensity==0);assert(!s.next(stop));
 // Publication during processing is drained without losing ownership.
 assert(s.publish(100,0));
 auto old=s.latest();assert(!s.publish(0,0));assert(s.next(old));
 assert(s.latest().intensity==0);assert(!s.next(s.latest()));
 // Parallel publishers must never strand the scheduler.
 constexpr int N=8,K=20000;
 std::atomic<bool> start{false};
 std::vector<std::thread> workers;
 std::atomic<int> claims{0};
 for(int i=0;i<N;++i)workers.emplace_back([&,i]{
  while(!start.load(std::memory_order_acquire))std::this_thread::yield();
  for(int j=0;j<K;++j)if(s.publish(i*100+j,i*100+j+1))++claims;
 });
 start=true;
 for(auto &t:workers)t.join();
 auto last=s.latest();
 assert(last.version==5+N*K);
 assert(!s.next(last));
 assert(s.publish(0,0));assert(s.latest().intensity==0);
 assert(!s.next(s.latest()));
 std::cout<<"PASS production scheduler ownership and 160000 concurrent publications\n";
}
