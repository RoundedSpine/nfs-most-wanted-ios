#include "../../kit/host/controls/haptics.h"
#include <cassert>
#include <cstdint>
#include <tuple>
#include <vector>
#include <iostream>
using namespace controls;
int main() {
    std::vector<std::tuple<char,uint16_t,uint16_t,uint32_t>> calls;
    RumbleRouter router({
        [&](uint16_t l,uint16_t h,uint32_t ms){calls.emplace_back('C',l,h,ms);},
        [&](uint16_t l,uint16_t h){calls.emplace_back('D',l,h,0);}
    });
    assert(rumble_sink(true,true)==RumbleSink::Controller);
    assert(rumble_sink(false,true)==RumbleSink::Device);
    assert(rumble_sink(false,false)==RumbleSink::None);
    router.update(1,100,200,RumbleSink::Device,100);
    assert(calls.size()==1 && std::get<0>(calls.back())=='D');
    router.update(1,100,200,RumbleSink::Device,200);
    assert(calls.size()==1);
    router.update(2,200,300,RumbleSink::Device,300);
    assert(calls.size()==2);
    router.update(3,200,300,RumbleSink::Controller,400);
    assert(calls.size()==4 && std::get<0>(calls[2])=='D' && std::get<1>(calls[2])==0 && std::get<0>(calls[3])=='C');
    router.update(4,0,0,RumbleSink::Controller,500);
    assert(calls.size()==5 && std::get<2>(calls.back())==0);
    router.update(4,0,0,RumbleSink::Controller,600);
    assert(calls.size()==5);
    router.update(5,10,20,RumbleSink::Device,700);
    router.stop();
    assert(std::get<1>(calls.back())==0 && std::get<0>(calls.back())=='D');
    auto before=calls.size();
    router.update(5,10,20,RumbleSink::Device,800);
    assert(calls.size()==before);
    router.update(6,10,20,RumbleSink::Device,900);
    assert(calls.size()==before+1);
    std::cout<<"PASS rumble router regression tests\n";
}
